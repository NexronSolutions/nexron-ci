-- good-storage fixture · platform-schema DML that CONFIGURES a bucket.
--
-- The sibling 20260101000001 fixture only names a bucket (id/name/public), so it
-- passes against a stub carrying identity columns alone. This one is the shape
-- that still broke the gate afterwards: pnbhs-crm
-- 20260708120200_event_expense_receipts_bucket.sql sets a size limit and a mime
-- allowlist, and aborted the whole replay with
--   ERROR: column "file_size_limit" of relation "buckets" does not exist
--
-- Keep both: the identity-only insert would go on passing even if the config
-- columns were dropped from the stub again, so it cannot protect this.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'receipts-fixture',
  'receipts-fixture',
  false,
  10485760,
  array['image/png', 'image/jpeg', 'application/pdf']
)
on conflict (id) do nothing;

-- Also exercise a RESTRICTIVE policy on storage.objects — the other half of that
-- migration, and the part that needs the stub's objects table plus enough
-- privilege for CREATE POLICY.
drop policy if exists fixture_receipts_deny_anon on storage.objects;
create policy fixture_receipts_deny_anon on storage.objects
  as restrictive
  for all
  to anon
  using (bucket_id <> 'receipts-fixture')
  with check (bucket_id <> 'receipts-fixture');
