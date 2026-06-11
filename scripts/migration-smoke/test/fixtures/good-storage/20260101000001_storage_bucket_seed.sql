-- good-storage fixture · platform-schema DML (the BUG-087 trigger shape)
-- Stand-in for pnbhs-crm 20260610093742_email_campaigns_data_layer.sql line 461:
-- a migration that writes to a Supabase-managed `storage` schema object. On a
-- bare engine container this aborts under ON_ERROR_STOP unless the harness has
-- seeded the storage stub first. This fixture must PASS once the stub exists.
insert into storage.buckets (id, name, public)
values ('campaign-images', 'campaign-images', true)
on conflict (id) do nothing;
