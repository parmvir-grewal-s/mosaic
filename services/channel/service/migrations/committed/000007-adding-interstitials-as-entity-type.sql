--! Previous: sha1:c64db838b70bcdcbe3ac7c3141bf1995c1269748
--! Hash: sha1:b67b9cbb3e5d5a671dff9260aadc970e11643727
--! Message: adding-interstitials-as-entity-type

INSERT INTO app_public.entity_type (value, description)
VALUES ('INTERSTITIAL', 'Interstitial')
ON CONFLICT (value) DO NOTHING;

GRANT UPDATE (video_duration_in_seconds) ON app_public.programs TO ":DATABASE_GQL_ROLE";
