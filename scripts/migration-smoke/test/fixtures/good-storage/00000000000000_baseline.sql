-- good-storage fixture · baseline (PII-clean public-schema squash)
-- Mirrors a normal Supabase baseline: public-schema DDL only, no data, no PII.
-- The PII gate scans THIS file (first in version order); it must stay clean.
create table if not exists public.campaigns (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  created_at  timestamptz not null default now()
);
alter table public.campaigns enable row level security;
