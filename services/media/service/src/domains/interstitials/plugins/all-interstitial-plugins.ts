import { makePluginByCombiningPlugins } from 'graphile-utils';
import { UpdateInterstitialDurationPlugin } from './update-interstitial-duration-plugin';

export const AllInterstitialPlugins = makePluginByCombiningPlugins(
  UpdateInterstitialDurationPlugin,
);
