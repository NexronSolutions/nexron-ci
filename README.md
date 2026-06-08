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

### Rollout

Advisory first (visible, non-blocking). Promote to a required status check via
branch protection only after a bake-in on a couple of real migration PRs.

### Phase 2 (deferred)

A prod-parity diff (`pg_dump --schema-only` prod via a dedicated **read-only**
role, diffed against the replay) is specced but not built — it needs a read-only
role + an encrypted secret, tracked as a separate follow-up.
