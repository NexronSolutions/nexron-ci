#!/usr/bin/env bash
#
# replay-smoke.sh — Phase 1 migration-smoke gate (closes BUG-078, Path B).
#
# Proves, from a clean substrate and using ONLY committed repo contents, that a
# Supabase repo can still rebuild its database from its own migration files —
# cleanly, deterministically, and without leaking member PII into the baseline.
#
# What it does (no secrets, never connects to any Supabase project / prod):
#   1. PII gate (baseline file only), run FIRST so a dirty baseline aborts before
#      any psql/apply can echo its literals into logs. BLOCKING on true
#      data-bearing/PII signals (email literals, the `matched_text` column,
#      top-level `COPY … FROM stdin` data blocks); the broader §8.8
#      INSERT/UPDATE/VALUES pattern is ADVISORY only (printed, never fails —
#      pg_dump --schema-only legitimately emits those inside CREATE FUNCTION
#      bodies). See the Path B plan §2 req#5 / §6 T-C.
#   2. Starts two clean, pinned Postgres containers.
#   3. Applies every top-level <14-digit-timestamp>_*.sql in version (lexical)
#      order, as role `postgres`, with ON_ERROR_STOP=1, check_function_bodies=off,
#      client_min_messages=warning. Skips _archive/ and non-timestamp files
#      (mirrors the Supabase CLI's non-recursive discovery).
#   4. Determinism: pg_dump --schema-only both containers and asserts the dumps
#      are byte-identical modulo per-invocation cosmetic tokens (\restrict).
#
# Parameterised by env (portable; no repo-specific paths):
#   MIGRATIONS_DIR  default: supabase/migrations
#   PG_IMAGE        default: supabase/postgres:17.6.1.084   (pinned; matches prod)
#   BASELINE_FILE   default: the first migration in version order (the squash)
#
# Exit code: 0 = all checks green; non-zero = a check failed (offending file /
# reason named on stderr).
#
set -euo pipefail

# ---- config -----------------------------------------------------------------
MIGRATIONS_DIR="${MIGRATIONS_DIR:-supabase/migrations}"
PG_IMAGE="${PG_IMAGE:-supabase/postgres:17.6.1.084}"
APPLY_ROLE="postgres"             # mirrors `supabase db push` / apply_migration
APPLY_DB="postgres"
READY_TIMEOUT="${READY_TIMEOUT:-90}"   # seconds to wait for each container

# Unique-ish container names (no Date.now/rand needed: PID is enough for a run).
RUN_TAG="migsmoke-$$"
C1="${RUN_TAG}-1"
C2="${RUN_TAG}-2"

WORKDIR="$(mktemp -d)"

# ---- logging helpers --------------------------------------------------------
log()  { printf '%s\n' "$*"; }
hdr()  { printf '\n=== %s ===\n' "$*"; }
fail() { printf '\nMIGRATION-SMOKE FAILED: %s\n' "$*" >&2; exit 1; }

cleanup() {
  docker rm -f "$C1" "$C2" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR" 2>/dev/null || true
}
trap cleanup EXIT

# ---- preflight --------------------------------------------------------------
command -v docker >/dev/null 2>&1 || fail "docker not found on PATH"
command -v rg     >/dev/null 2>&1 || fail "ripgrep (rg) not found on PATH"
[ -d "$MIGRATIONS_DIR" ] || fail "MIGRATIONS_DIR not found: $MIGRATIONS_DIR"

# ---- discover migrations (non-recursive; timestamped only) ------------------
# Top-level *.sql whose basename matches ^<14 digits>_…  — mirrors the CLI's
# fs.ReadDir (no _archive/ recursion, no README.md / non-conforming names).
MIGRATIONS=()
while IFS= read -r f; do
  [ -n "$f" ] && MIGRATIONS+=("$f")
done < <(
  find "$MIGRATIONS_DIR" -maxdepth 1 -type f -name '*.sql' -print \
    | while IFS= read -r p; do
        b="$(basename "$p")"
        [[ "$b" =~ ^[0-9]{14}_.*\.sql$ ]] && printf '%s\n' "$p"
      done \
    | LC_ALL=C sort
)
[ "${#MIGRATIONS[@]}" -gt 0 ] || fail "no <timestamp>_*.sql migrations found in $MIGRATIONS_DIR"
BASELINE_FILE="${BASELINE_FILE:-${MIGRATIONS[0]}}"

log "Migration-smoke replay"
log "  image:        $PG_IMAGE"
log "  migrations:   $MIGRATIONS_DIR (${#MIGRATIONS[@]} files, version order)"
log "  apply role:   $APPLY_ROLE"
log "  baseline:     $BASELINE_FILE"

# ---- 1. PII gate (baseline only) — runs BEFORE any container/apply ----------
# Ordering matters: scanning first means a dirty baseline aborts here, before
# apply/psql can echo its literals via an error tail into the logs + job summary.
# NEVER print matched line CONTENT: a real hit would leak the very
# email/secret/PII we're gating on. Scan in count-only mode (rg -c prints counts,
# never line bodies) and report redacted counts; inspect locally if a gate trips.
# Fail CLOSED: rg exits 0=match, 1=clean no-match, >=2=real error (bad PCRE / IO).
# A security scanner that silently passes on its own error is worse than useless,
# so an rg error aborts the gate rather than counting as "clean".
hdr "PII / secret scan (baseline: $(basename "$BASELINE_FILE"))"
pii_hit=0
scan_redacted() {
  local label="$1" pattern="$2" n rc=0
  n="$(rg -cP -- "$pattern" "$BASELINE_FILE" 2>/dev/null)" || rc=$?
  if [ "$rc" -ge 2 ]; then
    fail "PII scanner error (rg rc=$rc) on pattern [$label] — refusing to pass (fail-closed)"
  fi
  if [ "$rc" -eq 0 ] && [ -n "$n" ] && [ "$n" != "0" ]; then
    printf '  BLOCKING: %s — %s matching line(s) in baseline (content redacted)\n' "$label" "$n" >&2
    pii_hit=1
  fi
}
scan_redacted "email literal"                '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
scan_redacted "matched_text (PII free-text)" 'matched_text'
# Case-insensitive + allows leading whitespace so an indented/lowercase data dump
# can't slip past (superset of the plan's `^COPY .+ FROM stdin`).
scan_redacted "top-level COPY … FROM stdin"  '(?i)^\s*COPY\s+.+\s+FROM\s+stdin\b'
[ "$pii_hit" -eq 0 ] || fail "baseline contains data-bearing / PII signal(s) — see redacted counts above; run the scan locally to inspect the offending lines"
log "  BLOCKING scans clean (no email literals, no matched_text, no COPY data)"

log "  advisory (parent-plan §8.8 — CREATE FUNCTION-body DDL, not data; informational only):"
adv_count="$(rg -c "\b(INSERT INTO|UPDATE public\.|DELETE FROM|VALUES|COPY|DO \\\$\\\$)" "$BASELINE_FILE" || true)"
log "    ${adv_count:-0} advisory §8.8 line(s) in baseline (expected: function-body statements)"

# ---- container lifecycle ----------------------------------------------------
start_container() {
  local name="$1"
  docker run -d --name "$name" \
    -e POSTGRES_PASSWORD=postgres \
    "$PG_IMAGE" >/dev/null
  # Wait for the FINAL server, not the temporary bootstrap server.
  # supabase/postgres double-starts: a throwaway server runs the image's own
  # /docker-entrypoint-initdb.d migrations (which create the storage schema +
  # the supabase_* roles + grants), then shuts down and the real server starts.
  # That temp server answers on the unix socket, so a socket-only `pg_isready`
  # goes green mid-bootstrap — before roles/grants settle. The temp server does
  # NOT open TCP; only the final server listens on 127.0.0.1, so a TCP probe is
  # the gate that excludes the bootstrap phase (also true for a plain postgres
  # image, whose initdb server is socket-only too). Require both.
  local waited=0
  until docker exec "$name" pg_isready -U "$APPLY_ROLE" -d "$APPLY_DB" -q >/dev/null 2>&1 \
        && docker exec "$name" pg_isready -h 127.0.0.1 -U "$APPLY_ROLE" -d "$APPLY_DB" -q >/dev/null 2>&1; do
    sleep 2; waited=$((waited + 2))
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      docker logs "$name" 2>&1 | tail -n 40 >&2
      fail "container $name not ready after ${READY_TIMEOUT}s"
    fi
  done
}

# Apply one SQL file as role postgres with the discipline SETs + ON_ERROR_STOP.
# SETs are prepended in-session so they apply to the file's statements. We do
# NOT wrap in a single transaction — some migrations use CREATE INDEX
# CONCURRENTLY, which cannot run inside a transaction block.
apply_file() {
  local name="$1" file="$2" out
  out="$WORKDIR/apply.out"
  if { printf 'SET check_function_bodies=off;\nSET client_min_messages=warning;\n'; cat "$file"; } \
        | docker exec -i "$name" psql -U "$APPLY_ROLE" -d "$APPLY_DB" \
            -X -q -v ON_ERROR_STOP=1 -f - >"$out" 2>&1; then
    return 0
  fi
  printf '\nAPPLY FAILED: %s\n----- error (tail) -----\n' "$file" >&2
  tail -n 40 "$out" >&2
  return 1
}

apply_all() {
  local name="$1" verbose="$2" f
  for f in "${MIGRATIONS[@]}"; do
    if apply_file "$name" "$f"; then
      if [ "$verbose" = "1" ]; then log "  APPLY OK  $(basename "$f")"; fi
    else
      fail "migration did not apply on a clean container: $(basename "$f")"
    fi
  done
  return 0
}

# Seed a minimal Supabase-shaped `storage` schema on a fresh container BEFORE
# replay (BUG-087). On real Supabase the storage tables are provisioned by the
# storage-api service; the bare engine image ships an EMPTY `storage` schema
# (owned by supabase_admin) but no buckets/objects tables, so a migration doing
# platform-schema DML (e.g. `insert into storage.buckets …` — present on prod,
# R15 byte-locked, not editable) aborts under ON_ERROR_STOP. We stub only the
# column set Supabase ships (id/name/public/owner/bucket_id/created_at/updated_at
# + PK/FK), with RLS enabled on both tables. `objects` is included now because a
# later campaigns unit adds storage policies, which would otherwise re-break the
# gate.
#
# Roles: the apply role `postgres` holds only USAGE (not CREATE) on the
# supabase_admin-owned `storage` schema, so it cannot create the tables — exactly
# as on prod, where storage-api (role supabase_storage_admin) owns them. So we
# seed AS supabase_storage_admin (the one non-superuser role the image grants
# CREATE on `storage`), mirroring prod ownership, then GRANT the apply role the
# table privileges its DML needs. `postgres` carries BYPASSRLS on this image (as
# on prod), so its inserts still resolve despite RLS being enabled. Connecting as
# supabase_storage_admin uses the image's `host … 127.0.0.1/32 trust` pg_hba rule
# (the unix socket is peer-mapped to `postgres` only) — no password, no secret.
#
# Seeded IDENTICALLY on BOTH determinism containers, so the byte-identical
# pg_dump assertion stays valid. Anything beyond buckets/objects needs a harness
# PR first (see the pnbhs-crm supabase/migrations/README.md note).
STORAGE_SEED_ROLE="${STORAGE_SEED_ROLE:-supabase_storage_admin}"
STORAGE_STUB_SQL="
create schema if not exists storage;

create table if not exists storage.buckets (
  id         text        not null primary key,
  name       text        not null,
  owner      uuid,
  public     boolean     default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists storage.objects (
  id         uuid        not null default gen_random_uuid() primary key,
  bucket_id  text        references storage.buckets (id),
  name       text,
  owner      uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table storage.buckets enable row level security;
alter table storage.objects enable row level security;

grant all on storage.buckets, storage.objects to ${APPLY_ROLE};
"

seed_storage_stub() {
  local name="$1" out
  out="$WORKDIR/seed.out"
  # Connect over TCP (host 127.0.0.1 → trust per the image pg_hba) as the
  # storage-owner role, which is the only practical way to obtain CREATE on the
  # platform-owned `storage` schema. -h 127.0.0.1 also pins us to the final
  # server (the bootstrap server is socket-only).
  if printf '%s\n' "$STORAGE_STUB_SQL" \
        | docker exec -i "$name" psql -h 127.0.0.1 -U "$STORAGE_SEED_ROLE" -d "$APPLY_DB" \
            -X -q -v ON_ERROR_STOP=1 -f - >"$out" 2>&1; then
    return 0
  fi
  printf '\nSTORAGE STUB SEED FAILED on %s (seed role: %s)\n----- error (tail) -----\n' \
    "$name" "$STORAGE_SEED_ROLE" >&2
  tail -n 40 "$out" >&2
  return 1
}

# Normalise a schema dump for determinism comparison: blank the random token on
# the per-invocation \restrict / \unrestrict psql meta-commands (PG17 feature),
# which differ every dump but are cosmetic.
dump_schema() {
  local name="$1" outfile="$2"
  docker exec "$name" pg_dump -U "$APPLY_ROLE" -d "$APPLY_DB" --schema-only \
    | sed -E 's/^(\\(un)?restrict )[A-Za-z0-9_]+.*/\1<token>/' >"$outfile"
}

count_objects() {
  local name="$1" sql="$2"
  docker exec "$name" psql -U "$APPLY_ROLE" -d "$APPLY_DB" -X -t -A -c "$sql" 2>/dev/null | tr -d '[:space:]'
}

# ---- 2+3. start + apply -----------------------------------------------------
hdr "Starting clean containers ($PG_IMAGE)"
start_container "$C1"
start_container "$C2"
log "  both containers ready"

# Seed the storage platform-schema stub on BOTH containers before any apply, so
# migrations doing storage.* DML replay cleanly and both determinism substrates
# stay identical (BUG-087).
hdr "Seeding storage platform-schema stub on both containers (BUG-087)"
seed_storage_stub "$C1" || fail "storage stub seed failed on container 1"
seed_storage_stub "$C2" || fail "storage stub seed failed on container 2"
log "  storage stub seeded on both containers (buckets + objects, RLS enabled)"

hdr "Applying ${#MIGRATIONS[@]} migrations to container 1 (version order)"
apply_all "$C1" 1

hdr "Applying same set to container 2 (determinism substrate)"
apply_all "$C2" 0
log "  container 2 applied OK"

# ---- 4. determinism dump-diff ----------------------------------------------
hdr "Determinism check (pg_dump --schema-only, two fresh containers)"
dump_schema "$C1" "$WORKDIR/dump1.sql"
dump_schema "$C2" "$WORKDIR/dump2.sql"
if diff -u "$WORKDIR/dump1.sql" "$WORKDIR/dump2.sql" >"$WORKDIR/dump.diff"; then
  log "  determinism OK — schema dumps byte-identical (modulo \\restrict)"
else
  log "  --- schema delta (first 60 lines) ---" >&2
  head -n 60 "$WORKDIR/dump.diff" >&2
  fail "non-deterministic replay: schema dumps differ between two clean applies"
fi

# ---- summary ----------------------------------------------------------------
tables="$(count_objects "$C1" "SELECT count(*) FROM pg_tables WHERE schemaname='public';")"
funcs="$(count_objects "$C1" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public';")"

hdr "MIGRATION-SMOKE PASSED"
log "  migrations applied:   ${#MIGRATIONS[@]}"
log "  storage stub:         seeded on both containers (buckets + objects, RLS)"
log "  determinism:          OK (dumps identical modulo \\restrict)"
log "  baseline PII gate:    OK (blocking signals: 0)"
log "  public tables:        ${tables:-?}"
log "  public functions:     ${funcs:-?}"
exit 0
