-- bad-email fixture · baseline carrying a member email literal (PII).
-- The blocking email-literal scan must trip on this and FAIL the gate BEFORE any
-- container starts. Regression guard: storage-stub work must not weaken the gate.
create table if not exists public.members (
  id    uuid primary key default gen_random_uuid(),
  email text
);
insert into public.members (email) values ('jane.doe@example.com');
