import { gql, makeExtendSchemaPlugin } from 'graphile-utils';
import { getValidatedExtendedContext } from '../../../graphql/models';
import { duplicatePlaylist } from '../duplicating';

export const DuplicatePlaylistPlugin = makeExtendSchemaPlugin(() => {
  return {
    typeDefs: gql`
      input DuplicatePlaylistInput {
        playlistId: UUID!
        startDate: String!
        startTime: String!
      }

      type DuplicatePlaylistPayload {
        newPlaylistId: UUID!
      }

      extend type Mutation {
        duplicatePlaylist(
          input: DuplicatePlaylistInput!
        ): DuplicatePlaylistPayload!
      }
    `,
    resolvers: {
      Mutation: {
        duplicatePlaylist: async (_query, args, context) => {
          const { pgClient } = getValidatedExtendedContext(context);
          const { playlistId, startDate, startTime } = args.input;

          // Call the duplicatePlaylist function
          const newPlaylistId = await duplicatePlaylist(
            playlistId,
            startDate,
            startTime,
            pgClient,
          );

          return {
            newPlaylistId,
          };
        },
      },
    },
  };
});
