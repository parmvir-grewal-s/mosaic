--! Message: 000006-remove_video_id_not_null

ALTER TABLE app_public.programs
ALTER COLUMN video_id DROP NOT NULL;