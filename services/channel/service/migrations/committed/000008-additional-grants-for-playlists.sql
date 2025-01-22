--! Previous: sha1:b67b9cbb3e5d5a671dff9260aadc970e11643727
--! Hash: sha1:d5f7cc77b363425d3973a60ccede78902a475e4a
--! Message: additional-grants-for-playlists

GRANT SELECT, UPDATE, DELETE ON TABLE app_public.playlists TO ":DATABASE_GQL_ROLE";
GRANT INSERT (channel_id, title, start_date_time, calculated_duration_in_seconds, published_date, published_user, created_date, updated_date, updated_user, publication_state) ON app_public.playlists TO ":DATABASE_GQL_ROLE";
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE app_public.programs TO ":DATABASE_GQL_ROLE";
