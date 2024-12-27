/* eslint-disable no-console */
import { makeWrapResolversPlugin } from 'graphile-utils';
import { GraphQLClient } from 'graphql-request';
import { requestServiceAccountToken } from '../../../common/utils/token-utils';

export const SetProgramDurationPlugin = makeWrapResolversPlugin({
  Mutation: {
    createProgram: async (resolve, source, args, context, resolveInfo) => {
      console.log('createProgram plugin triggered'); // Check if the plugin is invoked
      console.log('Args received:', args); // Log the input arguments

      const { entityId, entityType } = args.input.program;

      // If the entity type is INTERSTITIAL
      console.log('Entity type:', entityType);
      if (entityType === 'INTERSTITIAL') {
        const config = {
          idServiceAuthBaseUrl: process.env.ID_SERVICE_AUTH_BASE_URL || '',
          serviceAccountClientId: process.env.SERVICE_ACCOUNT_CLIENT_ID || '',
          serviceAccountClientSecret:
            process.env.SERVICE_ACCOUNT_CLIENT_SECRET || '',
        };

        // Generate an access token for Media Service
        const accessToken = await requestServiceAccountToken(config);
        console.log('Access token generated:', accessToken); // Verify token generation

        // Fetch the interstitial duration from Media Service
        const client = new GraphQLClient(process.env.MEDIA_SERVICE_URL || '', {
          headers: {
            Authorization: `Bearer ${accessToken}`,
          },
        });

        const getInterstitialDurationQuery = `
          query interstitial($id: Int!) {
            interstitial(id: $id) {
              duration
            }
          }
        `;

        const result = await client.request(getInterstitialDurationQuery, {
          id: parseInt(entityId, 10),
        });

        console.log('Fetched interstitial duration:', result); // Log the fetched data

        const duration = result.interstitial?.duration;

        console.log('Calculated duration:', duration);

        // If duration exists, set it in videoDurationInSeconds
        if (duration) {
          args.input.program.videoDurationInSeconds = parseFloat(duration);
          console.log(
            'Updated videoDurationInSeconds:',
            args.input.program.videoDurationInSeconds,
          );
        }
      }

      // Pass modified args to the original resolver
      const result = await resolve(source, args, context, resolveInfo);
      console.log('Final result:', result);
      return result;
    },
  },
});
