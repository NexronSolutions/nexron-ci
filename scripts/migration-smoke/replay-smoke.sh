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
# Superuser used ONLY by the managed-schema shim (it owns the storage schema in
# this image). Migrations are never applied as this role — the gate would stop
# catching genuine permission defects. Password matches start_container's
# POSTGRES_PASSWORD; keep the two in step.
ADMIN_ROLE="supabase_admin"
ADMIN_PASS="postgres"
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
    -e POSTGRES_PASSWORD="$ADMIN_PASS" \
    "$PG_IMAGE" >/dev/null
  local waited=0
  until docker exec "$name" pg_isready -U "$APPLY_ROLE" -d "$APPLY_DB" -q >/dev/null 2>&1; do
    sleep 2; waited=$((waited + 2))
    if [ "$waited" -ge "$READY_TIMEOUT" ]; then
      docker logs "$name" 2>&1 | tail -n 40 >&2
      fail "container $name not ready after ${READY_TIMEOUT}s"
    fi
  done
}

# ---- Supabase-managed schema shim -------------------------------------------
# The pinned base image is Postgres + Supabase extensions/roles. It is NOT a
# running Supabase project, so schemas owned by the SERVICE layer (storage, and
# anything else the platform migrates independently of us) are absent or lag the
# shape a real project has. That is not a defect in the product repo's migrations:
# a migration that legitimately configures a storage bucket cannot replay against
# a container where storage.buckets has never been created by the storage service.
#
# Observed concretely: on the amd64 image storage.buckets exists but predates
# file_size_limit / allowed_mime_types; on arm64 the storage schema has no tables
# at all. Either way a migration touching storage aborts the whole replay and the
# gate reports a failure that says nothing about the migrations under test.
#
# So: before replaying, bring the managed surface up to the shape prod actually
# has. Modelled on the live project's storage.buckets (11 columns, incl. the
# storage.buckettype enum). Strictly additive and idempotent — CREATE IF NOT
# EXISTS / ADD COLUMN IF NOT EXISTS — so on an image that already ships the full
# shape this is a no-op and the replay still exercises the real thing.
#
# This shim is deliberately NARROW. It covers only what a product migration is
# entitled to assume exists; it does not simulate the storage service's behaviour,
# and it must never be extended to paper over a genuine defect in a migration.
managed_schema_shim() {
  local name="$1" out="$WORKDIR/shim.out"
  # Do NOT swallow this. A silently-failing shim resurfaces later as a confusing
  # migration failure with the real cause thrown away.
  # Runs as supabase_admin, not "$APPLY_ROLE": the storage schema is owned by
  # supabase_admin in this image and postgres cannot create in it. The storage
  # SERVICE would have made these objects; supabase_admin is the closest stand-in.
  if ! docker exec -i -e PGPASSWORD="$ADMIN_PASS" "$name" psql -U "$ADMIN_ROLE" -d "$APPLY_DB" \
        -X -q -v ON_ERROR_STOP=1 -f - >"$out" 2>&1 <<'SHIM'
CREATE SCHEMA IF NOT EXISTS storage;

DO $shim$
BEGIN
  IF to_regtype('storage.buckettype') IS NULL THEN
    CREATE TYPE storage.buckettype AS ENUM ('STANDARD', 'ANALYTICS');
  END IF;
END
$shim$;

CREATE TABLE IF NOT EXISTS storage.buckets (
  id                 text PRIMARY KEY,
  name               text NOT NULL,
  owner              uuid,
  created_at         timestamptz DEFAULT now(),
  updated_at         timestamptz DEFAULT now(),
  public             boolean DEFAULT false,
  avif_autodetection boolean DEFAULT false,
  file_size_limit    bigint,
  allowed_mime_types text[],
  owner_id           text,
  type               storage.buckettype NOT NULL DEFAULT 'STANDARD'
);

-- Older image shape: table present, newer columns missing.
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS public             boolean DEFAULT false;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS avif_autodetection boolean DEFAULT false;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS file_size_limit    bigint;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS allowed_mime_types text[];
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS owner_id           text;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS type               storage.buckettype NOT NULL DEFAULT 'STANDARD';

CREATE TABLE IF NOT EXISTS storage.objects (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id        text REFERENCES storage.buckets(id),
  name             text,
  owner            uuid,
  created_at       timestamptz DEFAULT now(),
  updated_at       timestamptz DEFAULT now(),
  last_accessed_at timestamptz DEFAULT now(),
  metadata         jsonb,
  path_tokens      text[],
  version          text,
  owner_id         text,
  user_metadata    jsonb
);

-- A real project has RLS on both; migrations add policies assuming it.
ALTER TABLE storage.buckets ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

-- Mirror prod: both tables are owned by supabase_storage_admin, with full grants
-- to postgres / service_role / authenticated / anon.
DO $shim$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    ALTER TABLE storage.buckets OWNER TO supabase_storage_admin;
    ALTER TABLE storage.objects OWNER TO supabase_storage_admin;

    GRANT ALL ON storage.buckets, storage.objects
      TO postgres, service_role, authenticated, anon;

    -- CREATE POLICY requires table ownership. On prod the applying identity can
    -- create policies on storage.objects (verified: the event-expense-receipts
    -- RESTRICTIVE policies exist there), but the container's postgres is neither
    -- superuser nor the owner. Granting the owner role reproduces prod's EFFECTIVE
    -- capability without making postgres a superuser — which would mask genuine
    -- permission defects everywhere else in the replay.
    GRANT supabase_storage_admin TO postgres;
  END IF;
END
$shim$;
SHIM
  then
    printf '\nMANAGED-SCHEMA SHIM FAILED on %s\n----- error (tail) -----\n' "$name" >&2
    tail -n 30 "$out" >&2
    return 1
  fi
  return 0
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

# Applied to BOTH containers identically, before either replay, so the
# determinism dump-diff still compares like with like.
managed_schema_shim "$C1"
managed_schema_shim "$C2"
log "  managed-schema shim applied (storage.buckets/objects at prod shape)"

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
log "  determinism:          OK (dumps identical modulo \\restrict)"
log "  baseline PII gate:    OK (blocking signals: 0)"
log "  public tables:        ${tables:-?}"
log "  public functions:     ${funcs:-?}"
exit 0
