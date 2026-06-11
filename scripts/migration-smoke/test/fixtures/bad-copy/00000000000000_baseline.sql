-- bad-copy fixture · baseline carrying a top-level `COPY … FROM stdin` data block.
-- The blocking COPY scan must trip on this and FAIL the gate. Regression guard for
-- the PII gate (must keep failing as before the storage-stub change).
create table if not exists public.seed_rows (
  id   int primary key,
  note text
);
COPY public.seed_rows (id, note) FROM stdin;
1	hello
\.
