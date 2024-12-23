import { makePluginByCombiningPlugins } from 'graphile-utils';
import { SetProgramDurationPlugin } from './set-program-duration-plugin';

export const AllInterstitialPlugins = makePluginByCombiningPlugins(
  SetProgramDurationPlugin,
);
