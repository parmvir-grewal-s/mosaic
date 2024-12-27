import { makePluginByCombiningPlugins } from 'graphile-utils';
import { UpdateEntityDurationPlugin } from './update-entity-duration-plugin';

export const AllEntityPlugins = makePluginByCombiningPlugins(
  UpdateEntityDurationPlugin,
);
