-- --! Message: og-title-and-ext-id-to-programs

ALTER TABLE app_public.programs ADD COLUMN IF NOT EXISTS external_id TEXT;
ALTER TABLE app_public.programs ADD COLUMN IF NOT EXISTS original_title TEXT;

GRANT INSERT (external_id, original_title) ON app_public.programs TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (external_id, original_title) ON app_public.programs TO ":DATABASE_GQL_ROLE";
