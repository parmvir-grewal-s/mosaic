import { BreadcrumbResolver } from '@axinom/mosaic-portal';
import { client } from '../../../apolloClient';
import {
  InterstitialTitleDocument,
  InterstitialTitleQuery,
} from '../../../generated/graphql';

export const InterstitialDetailsCrumb: BreadcrumbResolver = (params) => {
  return async (): Promise<string> => {
    const response = await client.query<InterstitialTitleQuery>({
      query: InterstitialTitleDocument,
      variables: {
        id: Number(params['interstitialId']),
      },
      errorPolicy: 'ignore',
    });
    return response.data.interstitial?.title || 'Interstitial Details';
  };
};
