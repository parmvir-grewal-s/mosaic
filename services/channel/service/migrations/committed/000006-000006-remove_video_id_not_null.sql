--! Previous: sha1:9e5086e5e54235c9638166bfa515fcb6c8252849
--! Hash: sha1:c64db838b70bcdcbe3ac7c3141bf1995c1269748
--! Message: 000006-remove_video_id_not_null

ALTER TABLE app_public.programs
ALTER COLUMN video_id DROP NOT NULL;
