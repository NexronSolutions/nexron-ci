-- bad-matched-text fixture · baseline carrying the `matched_text` PII column.
-- The blocking matched_text scan must trip on this and FAIL the gate. Regression
-- guard for the PII gate (must keep failing as before the storage-stub change).
create table if not exists public.pii_scan_hits (
  id           uuid primary key default gen_random_uuid(),
  matched_text text
);
