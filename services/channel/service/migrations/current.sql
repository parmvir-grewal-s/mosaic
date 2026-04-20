--! Message: adding-external_id-removing-original_title

-- Remove this comment line and write your migration here. Make sure to keep one empty line between 'Message' header and first migration line to properly name future migration file.
ALTER TABLE app_public.programs ADD COLUMN IF NOT EXISTS external_id TEXT;
GRANT INSERT (external_id) ON app_public.programs TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (external_id) ON app_public.programs TO ":DATABASE_GQL_ROLE";

ALTER TABLE app_public.programs DROP COLUMN IF EXISTS original_title;