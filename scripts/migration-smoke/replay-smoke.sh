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
#   5. safeupdate parity (PNBHS 2026-08-04 incident): proves the pinned image's
#      safeupdate guard behaves as prod's (bare UPDATE → 21000, WHERE true
#      passes), then sweeps the FINAL post-replay function bodies for
#      statement-initial UPDATE/DELETE without a syntactic WHERE — the exact
#      predicate prod enforces on every PostgREST session. Self-testing: the
#      sweep must flag an incident-shaped canary each run or the gate fails.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# Ledger registration splits SQL with the helper below; fail fast rather than
# part-way through a 100+ migration replay.
command -v python3 >/dev/null 2>&1 || fail "python3 not found on PATH (needed to register the migration ledger)"
[ -f "$SCRIPT_DIR/register-migration.py" ] \
  || fail "register-migration.py missing next to replay-smoke.sh"
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
      register_migration "$name" "$f" \
        || fail "applied but could not register in the ledger: $(basename "$f")"
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

-- Bucket-CONFIG columns. The original stub covered only identity columns, which
-- was enough for a bucket insert that just names a bucket. It is not enough for
-- one that configures it: pnbhs-crm 20260708120200_event_expense_receipts_bucket
-- inserts file_size_limit + allowed_mime_types and aborted the whole replay with
--   ERROR: column \"file_size_limit\" of relation \"buckets\" does not exist
-- Verified against the live project, where storage.buckets carries these.
--
-- Added via ALTER … IF NOT EXISTS rather than inside the CREATE above so the
-- stub also repairs an image whose storage.buckets already exists in an older
-- shape (observed: the amd64 image ships the table pre-dating these columns,
-- while arm64 ships no storage tables at all — CREATE IF NOT EXISTS alone
-- silently leaves the amd64 case short).
alter table storage.buckets add column if not exists file_size_limit    bigint;
alter table storage.buckets add column if not exists allowed_mime_types text[];
alter table storage.buckets add column if not exists avif_autodetection boolean default false;
alter table storage.buckets add column if not exists owner_id           text;
-- Not stubbed: storage.buckets.type (enum storage.buckettype). No migration
-- references it, and adding a custom type is more platform surface than the gate
-- needs. Add it here if one ever does.

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

# Seed the migration LEDGER before replay. Plain-psql replay never writes
# supabase_migrations.schema_migrations, so any migration that GUARDS on the
# ledger (the cutover-fence prerequisite/attestation pattern) can never apply —
# the gate then reports a failure that says nothing about the migration set.
# Shape mirrors prod: version is the PK, statements is the body array.
LEDGER_STUB_SQL="
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (
  version    text not null primary key,
  statements text[],
  name       text
);
"

seed_ledger_stub() {
  local name="$1" out
  out="$WORKDIR/ledger.out"
  if printf '%s\n' "$LEDGER_STUB_SQL" \
        | docker exec -i "$name" psql -U "$APPLY_ROLE" -d "$APPLY_DB" \
            -X -q -v ON_ERROR_STOP=1 -f - >"$out" 2>&1; then
    return 0
  fi
  printf '\nLEDGER STUB SEED FAILED on %s\n----- error (tail) -----\n' "$name" >&2
  tail -n 40 "$out" >&2
  return 1
}

# Record an applied migration in the ledger, mirroring `supabase db push`.
register_migration() {
  local name="$1" file="$2" out
  out="$WORKDIR/register.out"
  if python3 "$SCRIPT_DIR/register-migration.py" "$file" \
        | docker exec -i "$name" psql -U "$APPLY_ROLE" -d "$APPLY_DB" \
            -X -q -v ON_ERROR_STOP=1 -f - >"$out" 2>&1; then
    return 0
  fi
  printf '\nLEDGER REGISTER FAILED: %s\n----- error (tail) -----\n' "$file" >&2
  tail -n 40 "$out" >&2
  return 1
}

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

# ---- safeupdate parity leg (PNBHS 2026-08-04 incident, layer 2) --------------
# Supabase session-preloads `safeupdate` on the PostgREST role (authenticator),
# so at RUNTIME a bare UPDATE/DELETE (no syntactic WHERE) raises SQLSTATE 21000
# on EVERY API call — including inside plpgsql bodies, temp tables included —
# while this harness's apply path (role postgres, no safeupdate, function bodies
# never planned at CREATE) replays the same migration green. That gap shipped a
# ~19h outage: private.submit_registration_canonical carried two bare temp-table
# UPDATEs, every replay/pgTAP/direct-SQL check passed, and every prod submit
# 500'd. A replay harness that doesn't model prod's guard libraries is a control
# weaker than its name.
#
# Because the guard fires at execution time, "just LOAD safeupdate during apply"
# would NOT have caught it (the statements live inside function bodies, executed
# only when the RPC runs). The honest CI-side control is therefore two-part:
#   (a) GUARD PROOF — on the pinned image, prove safeupdate loads and actually
#       blocks a bare UPDATE with 21000 while `WHERE true` passes. If the image
#       ever drops or defangs the extension, the leg fails rather than silently
#       asserting a guard that no longer exists.
#   (b) FUNCTION-BODY SWEEP — after the full replay, statically scan the FINAL
#       pg_proc bodies (sql/plpgsql, user schemas) for statement-initial
#       UPDATE / DELETE FROM / WITH…UPDATE/DELETE with no syntactic WHERE —
#       the exact predicate safeupdate enforces. Final-state scanning (not
#       per-file) means a later CREATE OR REPLACE that fixes a body clears the
#       gate, mirroring what prod would execute. The sanctioned annotation for
#       an intentional full-table statement is `WHERE true` (the #227 fix
#       pattern) — there is deliberately no allowlist.
#   The sweep SELF-TESTS on every run: it must flag a canary function shaped
#   exactly like the incident (bare temp-table UPDATE) and must NOT flag its
#   `WHERE true` twin, or the leg fails — a check that cannot fail is
#   decoration.
#
# Known limitations (documented, not silently ignored): dynamic SQL inside
# EXECUTE '…' literals and statements hidden behind a semicolon inside a string
# literal are not parsed; both are rare and reviewable surface.
SWEEP_SQL="
with fn as (
  select n.nspname as schema, p.proname as fname,
         lower(regexp_replace(p.prosrc, '--[^\n]*', '', 'g')) as body
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where l.lanname in ('sql', 'plpgsql')
    and n.nspname not in (
      'pg_catalog', 'information_schema', 'extensions', 'auth', 'storage',
      'realtime', 'supabase_functions', 'graphql', 'graphql_public',
      'pgsodium', 'pgsodium_masks', 'vault', 'net', 'cron', 'pgbouncer',
      'repack', '_analytics', '_realtime', 'topology', 'tiger', 'tiger_data',
      'pgtle', 'dbdev', 'pgmq'
    )
),
stmts as (
  -- btrim with an explicit set: SQL trim() strips spaces ONLY, and split
  -- fragments open with the newline that followed the prior semicolon — a
  -- space-only trim leaves '^update' unanchorable (caught by the self-test).
  select fn.schema, fn.fname, t.ord, btrim(t.stmt, E' \t\n\r') as stmt
  from fn, regexp_split_to_table(fn.body, ';') with ordinality as t(stmt, ord)
)
select schema || '.' || fname || ' [stmt ' || ord || '] '
       || left(regexp_replace(stmt, '\s+', ' ', 'g'), 100)
from stmts
where (   stmt ~ '^update\s'
       or stmt ~ '^delete\s+from\s'
       or (stmt ~ '^with\s' and stmt ~ '\m(update|delete)\M')
      )
  and stmt !~ '\mwhere\M'
order by 1;
"

# The guard-proof sessions connect as GUARD_ROLE (default supabase_admin, the
# image superuser) over the TCP-trust path: supautils restricts LOAD for the
# apply role `postgres` ("access to library \"safeupdate\" is not allowed").
# Role choice does not weaken the proof — safeupdate's WHERE-clause check is
# session-wide and role-agnostic once loaded; prod attaches it to authenticator
# via session_preload_libraries the same way.
GUARD_ROLE="${GUARD_ROLE:-supabase_admin}"

safeupdate_guard_proof() {
  local name="$1" out rc
  out="$WORKDIR/safeupdate-proof.out"
  # Bare UPDATE under safeupdate MUST fail (the whole point of the guard)…
  rc=0
  docker exec -i "$name" psql -h 127.0.0.1 -U "$GUARD_ROLE" -d "$APPLY_DB" -X -q -v ON_ERROR_STOP=1 <<'SQL' >"$out" 2>&1 || rc=$?
LOAD 'safeupdate';
begin;
create temporary table migsmoke_guard_canary (x int) on commit drop;
insert into migsmoke_guard_canary values (1);
update migsmoke_guard_canary set x = 2;
commit;
SQL
  if [ "$rc" -eq 0 ]; then
    fail "safeupdate guard proof: a bare UPDATE was NOT blocked on $PG_IMAGE — the image no longer models prod's guard; do not trust this leg (or the image pin) until resolved"
  fi
  grep -qiE "WHERE clause|21000" "$out" \
    || { tail -n 10 "$out" >&2; fail "safeupdate guard proof: bare UPDATE failed for an unexpected reason (not the safeupdate WHERE-clause guard)"; }
  # …and the sanctioned `WHERE true` escape hatch MUST pass.
  rc=0
  docker exec -i "$name" psql -h 127.0.0.1 -U "$GUARD_ROLE" -d "$APPLY_DB" -X -q -v ON_ERROR_STOP=1 <<'SQL' >"$out" 2>&1 || rc=$?
LOAD 'safeupdate';
begin;
create temporary table migsmoke_guard_canary2 (x int) on commit drop;
insert into migsmoke_guard_canary2 values (1);
update migsmoke_guard_canary2 set x = 2 where true;
commit;
SQL
  if [ "$rc" -ne 0 ]; then
    tail -n 10 "$out" >&2
    fail "safeupdate guard proof: UPDATE … WHERE true was blocked — guard semantics differ from the assumed model"
  fi
  return 0
}

run_sweep() {
  # Prints one offender per line; empty output = clean. psql errors fail closed
  # via ON_ERROR_STOP + the caller's rc check (never swallow a scanner error).
  local name="$1"
  docker exec "$name" psql -U "$APPLY_ROLE" -d "$APPLY_DB" \
    -X -t -A -v ON_ERROR_STOP=1 -c "$SWEEP_SQL"
}

safeupdate_sweep() {
  local name="$1" selftest_out sweep_out rc
  # Self-test first: the sweep must catch the incident shape and pass its twin.
  rc=0
  docker exec -i "$name" psql -U "$APPLY_ROLE" -d "$APPLY_DB" -X -q -v ON_ERROR_STOP=1 <<'SQL' >"$WORKDIR/sweep-selftest-setup.out" 2>&1 || rc=$?
create schema migsmoke_selftest;
create function migsmoke_selftest.canary_bare_update() returns void
language plpgsql as $fn$
begin
  create temporary table if not exists tmp_migsmoke_canary (x int) on commit drop;
  -- the 2026-08-04 incident shape: temp-table UPDATE, no WHERE
  update tmp_migsmoke_canary set x = 1;
end
$fn$;
create function migsmoke_selftest.canary_where_true() returns void
language plpgsql as $fn$
begin
  create temporary table if not exists tmp_migsmoke_canary2 (x int) on commit drop;
  update tmp_migsmoke_canary2 set x = 1 where true;
end
$fn$;
SQL
  [ "$rc" -eq 0 ] || { tail -n 10 "$WORKDIR/sweep-selftest-setup.out" >&2; fail "safeupdate sweep self-test: canary setup failed"; }

  rc=0
  selftest_out="$(run_sweep "$name")" || rc=$?
  [ "$rc" -eq 0 ] || fail "safeupdate sweep self-test: sweep query errored (rc=$rc) — refusing to pass (fail-closed)"
  printf '%s\n' "$selftest_out" | grep -q 'migsmoke_selftest\.canary_bare_update' \
    || fail "safeupdate sweep self-test: the sweep did NOT flag the incident-shaped canary — the check is decoration; fix the sweep before trusting the gate"
  if printf '%s\n' "$selftest_out" | grep -q 'migsmoke_selftest\.canary_where_true'; then
    fail "safeupdate sweep self-test: the sweep flagged the WHERE-true twin — over-broad predicate would red every repo"
  fi

  docker exec "$name" psql -U "$APPLY_ROLE" -d "$APPLY_DB" -X -q -v ON_ERROR_STOP=1 \
    -c 'drop schema migsmoke_selftest cascade;' >/dev/null 2>&1 \
    || fail "safeupdate sweep self-test: canary teardown failed"

  # Production sweep on the replayed final state.
  rc=0
  sweep_out="$(run_sweep "$name")" || rc=$?
  [ "$rc" -eq 0 ] || fail "safeupdate sweep: sweep query errored (rc=$rc) — refusing to pass (fail-closed)"
  if [ -n "$sweep_out" ]; then
    printf '\n  bare UPDATE/DELETE (no WHERE) in final function bodies — these raise SQLSTATE 21000 on every PostgREST call under prod safeupdate:\n' >&2
    printf '%s\n' "$sweep_out" | sed 's/^/    /' >&2
    printf '  fix: add a real WHERE, or `WHERE true` for an intentional full-table statement (the #227 pattern).\n' >&2
    fail "safeupdate parity: $(printf '%s\n' "$sweep_out" | grep -c .) statement(s) prod would block at runtime"
  fi
  return 0
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

hdr "Seeding migration ledger on both containers (ledger-guarded migrations)"
seed_ledger_stub "$C1" || fail "ledger stub seed failed on container 1"
seed_ledger_stub "$C2" || fail "ledger stub seed failed on container 2"
log "  ledger seeded on both containers (supabase_migrations.schema_migrations)"

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

# ---- 5. safeupdate parity leg ----------------------------------------------
# AFTER the determinism dumps: the sweep's canary objects live briefly on C1 and
# must never be able to skew the dump comparison.
hdr "safeupdate parity (guard proof + final function-body sweep)"
safeupdate_guard_proof "$C1"
log "  guard proof OK — bare UPDATE blocked (21000), WHERE true passes"
safeupdate_sweep "$C1"
log "  sweep OK — self-test caught the incident-shaped canary; final bodies carry no bare UPDATE/DELETE"

# ---- summary ----------------------------------------------------------------
tables="$(count_objects "$C1" "SELECT count(*) FROM pg_tables WHERE schemaname='public';")"
funcs="$(count_objects "$C1" "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public';")"

hdr "MIGRATION-SMOKE PASSED"
log "  migrations applied:   ${#MIGRATIONS[@]}"
log "  storage stub:         seeded on both containers (buckets + objects, RLS)"
log "  migration ledger:     registered ${#MIGRATIONS[@]} rows (db push semantics)"
log "  determinism:          OK (dumps identical modulo \\restrict)"
log "  safeupdate parity:    OK (guard proven on image; function-body sweep clean)"
log "  baseline PII gate:    OK (blocking signals: 0)"
log "  public tables:        ${tables:-?}"
log "  public functions:     ${funcs:-?}"
exit 0
