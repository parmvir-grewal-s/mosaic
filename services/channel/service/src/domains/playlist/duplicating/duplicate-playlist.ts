import { MosaicError } from '@axinom/mosaic-service-common';
import { ClientBase } from 'pg';
import { insert, select, selectOne } from 'zapatos/db';
import { CommonErrors } from '../../../common';

/**
 * Duplicates a playlist with a new start date and time.
 * @param playlistId The ID of the playlist to duplicate.
 * @param startDate The new start date for the duplicated playlist.
 * @param startTime The new start time for the duplicated playlist.
 * @param client The database client.
 * @returns The ID of the new playlist.
 */
export async function duplicatePlaylist(
  playlistId: string,
  startDate: string,
  startTime: string,
  client: ClientBase,
): Promise<string> {
  // Fetch the original playlist
  const originalPlaylist = await selectOne('playlists', { id: playlistId }).run(
    client,
  );

  if (!originalPlaylist) {
    throw new MosaicError({
      ...CommonErrors.PlaylistNotFound,
      details: { playlistId },
    });
  }

  // Combine startDate and startTime into ISO format for start_date_time
  const newStartDateTime = new Date(`${startDate}T${startTime}`).toISOString();

  // Insert the duplicated playlist
  const newPlaylist = await insert('playlists', {
    channel_id: originalPlaylist.channel_id,
    title: startDate, // Set the title as the start date
    start_date_time: newStartDateTime,
    calculated_duration_in_seconds:
      originalPlaylist.calculated_duration_in_seconds,
    publication_state: 'NOT_PUBLISHED',
    created_date: new Date().toISOString(),
    updated_date: new Date().toISOString(),
  }).run(client);

  // Duplicate associated programs
  const programs = await select('programs', { playlist_id: playlistId }).run(
    client,
  );

  if (programs.length > 0) {
    for (const program of programs) {
      await insert('programs', {
        playlist_id: newPlaylist.id,
        title: program.title,
        video_id: program.video_id,
        entity_id: program.entity_id,
        entity_type: program.entity_type,
        sort_index: program.sort_index,
        video_duration_in_seconds: program.video_duration_in_seconds,
        created_date: new Date().toISOString(),
        updated_date: new Date().toISOString(),
      }).run(client);
    }
  }

  return newPlaylist.id;
}
