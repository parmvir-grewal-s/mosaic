--! Previous: sha1:7ba6343a18c70c36843b3779de69a5ca2cdc9531
--! Hash: sha1:46b31f318aab7ea2a69453308675dc782c69ccb3

ALTER TABLE app_public.interstitials ADD COLUMN IF NOT EXISTS duration NUMERIC(13, 5);

GRANT INSERT (duration) ON app_public.interstitials TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (duration) ON app_public.interstitials TO ":DATABASE_GQL_ROLE";
