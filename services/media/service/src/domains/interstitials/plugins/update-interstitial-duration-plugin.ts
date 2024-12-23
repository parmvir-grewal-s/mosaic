import { makeWrapResolversPlugin } from 'graphile-utils';
import { Pool } from 'pg';

export const UpdateInterstitialDurationPlugin = makeWrapResolversPlugin({
  Mutation: {
    updateInterstitial: async (resolve, source, args, context, resolveInfo) => {
      const result = await resolve(source, args, context, resolveInfo);

      const channelDbClient = new Pool({
        connectionString: process.env.CHANNEL_SERVICE_DATABASE_URL,
      });

      // Check if duration is being updated
      const patch = args.input.patch;
      if (patch && patch.duration) {
        const interstitialId = args.input.id;

        // Query programs in the Channel Service to find associated playlists
        const { rows: programs } = await channelDbClient.query(
          `
          SELECT id
          FROM app_public.programs
          WHERE entity_id = $1 AND entity_type = 'INTERSTITIAL'
          `,
          [interstitialId],
        );

        // Update the videoDurationInSeconds in the Channel Service
        for (const program of programs) {
          await channelDbClient.query(
            `
            UPDATE app_public.programs
            SET video_duration_in_seconds = $1
            WHERE id = $2
            `,
            [patch.duration, program.id],
          );
        }
      }
      await channelDbClient.end();
      return result;
    },
  },
});
