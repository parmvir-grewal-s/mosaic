--! Message: adding-interstitials-as-entity-type

INSERT INTO app_public.entity_type (value, description)
VALUES ('INTERSTITIAL', 'Interstitial')
ON CONFLICT (value) DO NOTHING;

GRANT UPDATE (video_duration_in_seconds) ON app_public.programs TO ":DATABASE_GQL_ROLE";