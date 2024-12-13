import {
  Mutations as M,
  Queries as Q,
} from '../../generated/graphql/operations';

export const InterstitialsReadOperations = [Q.interstitial, Q.interstitials];
export const InterstitialsMutateOperations = [
  M.createInterstitial,
  M.deleteInterstitial,
  M.updateInterstitial,
];
