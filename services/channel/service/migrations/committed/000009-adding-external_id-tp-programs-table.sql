--! Previous: sha1:d5f7cc77b363425d3973a60ccede78902a475e4a
--! Hash: sha1:221985c38dc7aeb77947aa8de6eeb9a7ddc2de15
--! Message: adding-external_id-tp-programs-table

ALTER TABLE app_public.programs ADD COLUMN IF NOT EXISTS external_id TEXT;
GRANT INSERT (external_id) ON app_public.programs TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (external_id) ON app_public.programs TO ":DATABASE_GQL_ROLE";
