import { Logger } from '@axinom/mosaic-service-common';
import { gql, makeExtendSchemaPlugin } from 'graphile-utils';
import { insert, select } from 'zapatos/db';
import { getValidatedExtendedContext } from '../../../graphql/models';

const logger = new Logger({ context: 'duplicate-playlist-plugin' });

export const DuplicatePlaylistPlugin = makeExtendSchemaPlugin((build) => {
  return {
    typeDefs: gql`
      """
      The input details to duplicate a playlist.
      """
      input DuplicatePlaylistInput {
        """
        Unique Identifier of the playlist to duplicate.
        """
        playlistId: UUID!
        """
        The new start date for the duplicated playlist.
        """
        startDate: String!
        """
        The new start time for the duplicated playlist.
        """
        startTime: String!
        """
        An arbitrary string value with no semantic meaning. Will be included in the
        payload verbatim. May be used to track mutations by the client.
        """
        clientMutationId: String
      }

      """
      The duplicated playlist in the defined format.
      """
      type DuplicatePlaylistPayload {
        """
        The duplicated playlist.
        """
        playlist: Playlist! @pgField
        """
        The exact same \`clientMutationId\` that was provided in the mutation input,
        unchanged and unused. May be used by a client to track mutations.
        """
        clientMutationId: String
        query: Query
      }

      extend type Mutation {
        """
        Duplicate a playlist with a new start date and time.
        """
        duplicatePlaylist(
          input: DuplicatePlaylistInput!
        ): DuplicatePlaylistPayload!
      }
    `,
    resolvers: {
      Mutation: {
        duplicatePlaylist: async (
          _source: unknown,
          {
            input,
          }: {
            input: {
              playlistId: string;
              startDate: string;
              startTime: string;
              clientMutationId?: string;
            };
          },
          context,
          { graphile },
        ) => {
          const { playlistId, startDate, startTime, clientMutationId } = input;

          try {
            const { pgClient } = getValidatedExtendedContext(context);

            // Fetch the original playlist
            const originalPlaylist = await select('playlists', {
              id: playlistId,
            }).run(pgClient);

            if (!originalPlaylist) {
              throw new Error(
                `Playlist with ID '${playlistId}' does not exist.`,
              );
            }

            const startDateTime = new Date(`${startDate}T${startTime}`); // Combine date and time
            // Insert the new playlist
            const newPlaylist = await insert(
              'playlists',
              {
                channel_id: originalPlaylist[0].channel_id, // Ensure this is from the original playlist
                title: `${startDate}`, // Optionally modify title to distinguish duplicates
                start_date_time: new Date(startDateTime), // Use combined date and time
                calculated_duration_in_seconds:
                  originalPlaylist[0].calculated_duration_in_seconds || 0, // Fallback if undefined
                created_date: new Date(),
                updated_date: new Date(),
                publication_state: 'NOT_PUBLISHED',
              },
              { returning: ['id'] },
            ).run(pgClient);

            // Fetch the programs associated with the original playlist
            const programs = await select('programs', {
              playlist_id: playlistId,
            }).run(pgClient);

            // Duplicate the programs and associate them with the new playlist
            for (const program of programs) {
              await insert('programs', {
                ...program,
                id: undefined, // Let the database generate a new ID
                playlist_id: newPlaylist.id,
              }).run(pgClient);
            }

            // Return the duplicated playlist as part of the GraphQL response
            const duplicatedPlaylist = await select('playlists', {
              id: newPlaylist.id,
            }).run(pgClient);

            logger.debug(
              `Playlist '${playlistId}' successfully duplicated as '${newPlaylist.id}'.`,
            );

            return {
              playlist: duplicatedPlaylist,
              clientMutationId,
              query: graphile.build.$$isQuery,
            };
          } catch (error) {
            logger.error(`Failed to duplicate playlist: ${error}`);
            throw error;
          }
        },
      },
    },
  };
});
