--! Message: add-duration-to-interstitial

ALTER TABLE app_public.interstitials ADD COLUMN duration NUMERIC(13, 5);

GRANT INSERT (duration) ON app_public.interstitials TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (duration) ON app_public.interstitials TO ":DATABASE_GQL_ROLE";
