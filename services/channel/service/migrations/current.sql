--! Message: adding-external_id-removing-original_title

ALTER TABLE app_public.programs ADD COLUMN IF NOT EXISTS external_id TEXT;
GRANT INSERT (external_id) ON app_public.programs TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (external_id) ON app_public.programs TO ":DATABASE_GQL_ROLE";