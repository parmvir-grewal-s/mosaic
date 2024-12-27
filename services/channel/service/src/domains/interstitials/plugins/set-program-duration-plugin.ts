import { makeWrapResolversPlugin } from 'graphile-utils';
import { GraphQLClient } from 'graphql-request';
import { requestServiceAccountToken } from '../../../common/utils/token-utils';

export const SetProgramDurationPlugin = makeWrapResolversPlugin({
  Mutation: {
    createProgram: async (resolve, source, args, context, resolveInfo) => {
      const programInput = args.input.program;

      if (programInput.entityType && programInput.entityId) {
        const config = {
          idServiceAuthBaseUrl: process.env.ID_SERVICE_AUTH_BASE_URL || '',
          serviceAccountClientId: process.env.SERVICE_ACCOUNT_CLIENT_ID || '',
          serviceAccountClientSecret:
            process.env.SERVICE_ACCOUNT_CLIENT_SECRET || '',
        };

        // Generate the access token
        const accessToken = await requestServiceAccountToken(config);

        // Set up GraphQL client for media-service
        const client = new GraphQLClient(process.env.MEDIA_SERVICE_URL || '', {
          headers: {
            Authorization: `Bearer ${accessToken}`,
          },
        });

        // GraphQL query to fetch entity's duration
        const getEntityDurationQuery = `
          query GetEntity($id: Int!) {
            ${programInput.entityType.toLowerCase()}(id: $id) {
              duration
            }
          }
        `;

        // Ensure the `entityId` is an integer
        const entityId = parseInt(programInput.entityId, 10);

        // Fetch the duration for the entity
        const entityTypeLower = programInput.entityType.toLowerCase();
        const { [entityTypeLower]: entity } = await client.request(
          getEntityDurationQuery,
          {
            id: entityId,
          },
        );

        if (entity && entity.duration) {
          programInput.videoDurationInSeconds = entity.duration;
        }
      }

      return resolve(source, args, context, resolveInfo);
    },
  },
});
