# nexron-ci

Shared CI tooling for Nexron Supabase repos. Public by design: it holds only
generic CI logic (no secrets, no PII, no product code), which lets product repos
consume it with a tokenless checkout.

## migration-smoke (Phase 1 — Path B, closes BUG-078)

Proves, on every PR that touches a repo's `supabase/migrations/`, that the repo
can still rebuild its database from its own committed migration files —
**cleanly**, **deterministically**, and without leaking member PII into the
baseline. Phase 1 uses **no secrets** and **never connects to any Supabase
project or prod**; it runs entirely against ephemeral local containers.

### What it checks

1. **Clean replay** — applies every top-level `<14-digit-timestamp>_*.sql` in
   version order to a clean `supabase/postgres` container, as role `postgres`,
   with `ON_ERROR_STOP=1`, `check_function_bodies=off`,
   `client_min_messages=warning`. `_archive/` and non-timestamp files are skipped
   (mirrors the Supabase CLI's non-recursive discovery).
2. **Determinism** — applies the same set to a second clean container,
   `pg_dump --schema-only` both, and asserts the dumps are byte-identical modulo
   per-invocation cosmetic `\restrict` tokens.
3. **Baseline PII gate** — BLOCKS on true data-bearing/PII signals in the
   baseline (email literals, the `matched_text` column, top-level
   `COPY … FROM stdin` data blocks). The broader parent-plan §8.8
   `INSERT/UPDATE/VALUES` pattern is printed as **advisory** only — a
   `pg_dump --schema-only` legitimately emits those inside `CREATE FUNCTION`
   bodies.

### Storage platform-schema stub (BUG-087)

Supabase provisions the `storage` schema (and its `buckets`/`objects` tables)
via the storage-api service. A bare `supabase/postgres` engine container ships
the empty schema but **no** tables, so a migration that does platform-schema DML
— e.g. `insert into storage.buckets …` — would abort the clean replay. Before
applying any migration, the harness seeds a minimal, Supabase-shaped stub on
**both** determinism containers: `storage.buckets` and `storage.objects` with the
column set Supabase ships (`id`/`name`/`public`/`owner`/`bucket_id`/`created_at`/
`updated_at` + PK/FK), RLS enabled on both. The stub is created as
`supabase_storage_admin` (the role that owns these tables on prod) over the
image's localhost-trust `pg_hba` rule — still **no secrets** — and the apply role
is granted the privileges its DML needs.

The stub covers `buckets` + `objects` only. A migration touching any **other**
platform-managed schema/object needs a harness PR to extend the stub first — it
is not a licence for arbitrary `storage`/`auth`/… DML. See the consuming repo's
`supabase/migrations/README.md` note.

### Adopt it (thin caller in a product repo)

`.github/workflows/migration-smoke.yml`:

```yaml
name: migration-smoke
on:
  pull_request:
    paths:
      - 'supabase/migrations/**'
jobs:
  migration-smoke:
    uses: NexronS2025/nexron-ci/.github/workflows/migration-smoke.yml@v1
```

Inputs (both optional):

| input | default |
|---|---|
| `migrations_dir` | `supabase/migrations` |
| `pg_image` | `supabase/postgres:17.6.1.084` (pinned) |

### Run the script locally

```bash
PG_IMAGE=supabase/postgres:17.6.1.084 MIGRATIONS_DIR=supabase/migrations \
  bash scripts/migration-smoke/replay-smoke.sh
```

Requires `docker` and `ripgrep` (`rg`) on `PATH`.

### Regression tests

```bash
bash scripts/migration-smoke/test/run-tests.sh
```

Drives the gate against fixed fixtures and asserts each behaves as it should: a
known-good set whose later migration does `storage.buckets` DML must **pass**
(guards the BUG-087 stub), and the `bad-email` / `bad-matched-text` / `bad-copy`
fixtures must **fail** (guard the blocking PII gate). Same `docker` + `rg`
prerequisites as the script itself.

### Rollout

Advisory first (visible, non-blocking). Promote to a required status check via
branch protection only after a bake-in on a couple of real migration PRs.

### Phase 2 (deferred)

A prod-parity diff (`pg_dump --schema-only` prod via a dedicated **read-only**
role, diffed against the replay) is specced but not built — it needs a read-only
role + an encrypted secret, tracked as a separate follow-up.
