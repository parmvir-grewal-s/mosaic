--! Previous: sha1:46b31f318aab7ea2a69453308675dc782c69ccb3
--! Hash: sha1:7b8454bb2604460da181c2f477160b3f381a3847
--! Message: add-duration-to-movies-and-episodes

-- Add duration column to movies
ALTER TABLE app_public.movies ADD COLUMN IF NOT EXISTS duration NUMERIC(13, 5);

GRANT INSERT (duration) ON app_public.movies TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (duration) ON app_public.movies TO ":DATABASE_GQL_ROLE";

-- Add duration column to episodes
ALTER TABLE app_public.episodes ADD COLUMN IF NOT EXISTS duration NUMERIC(13, 5);

GRANT INSERT (duration) ON app_public.episodes TO ":DATABASE_GQL_ROLE";
GRANT UPDATE (duration) ON app_public.episodes TO ":DATABASE_GQL_ROLE";
