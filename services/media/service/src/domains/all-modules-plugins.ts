import { SubscriptionsPluginFactory } from '@axinom/mosaic-graphql-common';
import { makePluginByCombiningPlugins } from 'graphile-utils';
import { AllCollectionDevPlugins, AllCollectionPlugins } from './collections';
import { AllEntityPlugins } from './interstitials/plugins/all-entity-plugins';
import { AllMovieDevPlugins, AllMoviePlugins } from './movies';
import { AllTvshowDevPlugins, AllTvshowPlugins } from './tvshows';

export const AllModulesPlugins = makePluginByCombiningPlugins(
  AllCollectionPlugins,
  AllMoviePlugins,
  AllTvshowPlugins,
  AllEntityPlugins,
);

export const AllModulesDevPlugins = makePluginByCombiningPlugins(
  AllCollectionDevPlugins,
  AllMovieDevPlugins,
  AllTvshowDevPlugins,
  AllEntityPlugins,
);

export const AllSubscriptionsPlugins = makePluginByCombiningPlugins(
  SubscriptionsPluginFactory('ingest_documents', 'IngestDocument'),
  SubscriptionsPluginFactory('snapshots', 'Snapshot'),
  SubscriptionsPluginFactory('collections', 'Collection'),
  SubscriptionsPluginFactory('movie_genres', 'MovieGenre'),
  SubscriptionsPluginFactory('movies', 'Movie'),
  SubscriptionsPluginFactory('tvshow_genres', 'TvshowGenre'),
  SubscriptionsPluginFactory('tvshows', 'Tvshow'),
  SubscriptionsPluginFactory('seasons', 'Season'),
  SubscriptionsPluginFactory('episodes', 'Episode'),
  SubscriptionsPluginFactory('interstitials', 'Interstitial'),
);
