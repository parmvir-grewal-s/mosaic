--! Previous: sha1:221985c38dc7aeb77947aa8de6eeb9a7ddc2de15
--! Hash: sha1:df0292c9a2b41229a4511f7209f25461d26d64fc
--! Message: adding-original-title-to-programs-table

ALTER TABLE app_public.programs ADD COLUMN IF NOT EXISTS original_title TEXT;
GRANT INSERT (original_title) ON app_public.programs TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (original_title) ON app_public.programs TO ":DATABASE_GQL_ROLE";
