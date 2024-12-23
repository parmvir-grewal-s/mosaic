import { makeWrapResolversPlugin } from 'graphile-utils';
import { GraphQLClient } from 'graphql-request';
import { requestServiceAccountToken } from '../../../common/utils/token-utils';

export const UpdateInterstitialDurationPlugin = makeWrapResolversPlugin({
  Mutation: {
    updateInterstitial: async (resolve, source, args, context, resolveInfo) => {
      const result = await resolve(source, args, context, resolveInfo);

      // Check if duration is being updated
      const patch = args.input.patch;
      if (patch && patch.duration) {
        const interstitialId = args.input.id;

        const config = {
          idServiceAuthBaseUrl: process.env.ID_SERVICE_AUTH_BASE_URL || '',
          serviceAccountClientId: process.env.SERVICE_ACCOUNT_CLIENT_ID || '',
          serviceAccountClientSecret:
            process.env.SERVICE_ACCOUNT_CLIENT_SECRET || '',
        };

        // Generate the access token
        const accessToken = await requestServiceAccountToken(config);

        // Set up GraphQL client for channel-service
        const client = new GraphQLClient(
          process.env.CHANNEL_SERVICE_URL || '',
          {
            headers: {
              Authorization: `Bearer ${accessToken}`,
            },
          },
        );

        // GraphQL query to fetch associated programs from channel-service
        const getProgramsQuery = `
          query GetPrograms($entityId: String!) {
            programs(filter: { entityId: { equalTo: $entityId }, entityType: { equalTo: INTERSTITIAL } }) {
              nodes {
                id
              }
            }
          }
        `;

        // Fetch programs associated with this Interstitial
        const { programs } = await client.request(getProgramsQuery, {
          entityId: String(interstitialId),
          entityType: 'INTERSTITIAL',
        });

        // Update videoDurationInSeconds for each program
        const updateProgramMutation = `
          mutation UpdateProgram($id: UUID!, $patch: ProgramPatch!) {
            updateProgram(input: { id: $id, patch: $patch }) {
              program {
                id
                videoDurationInSeconds
              }
            }
          }
        `;

        for (const program of programs.nodes) {
          await client.request(updateProgramMutation, {
            id: program.id,
            patch: { videoDurationInSeconds: parseFloat(patch.duration) },
          });
        }
      }
      return result;
    },
  },
});