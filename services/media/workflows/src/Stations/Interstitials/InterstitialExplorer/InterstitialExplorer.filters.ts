import {
  createDateRangeFilterValidators,
  filterToPostGraphileFilter,
  FilterType,
  FilterTypes,
  FilterValues,
} from '@axinom/mosaic-ui';
import { InterstitialFilter } from '../../../generated/graphql';
import { InterstitialData } from './InterstitialExplorer.types';

export function useInterstitialsFilters(): {
  readonly filterOptions: FilterType<InterstitialData>[];
  readonly transformFilters: (
    filters: FilterValues<InterstitialData>,
    excludeItems?: number[],
  ) => InterstitialFilter | undefined;
} {
  const [createFromDateFilterValidator, createToDateFilterValidator] =
    createDateRangeFilterValidators<InterstitialData>();

  const filterOptions: FilterType<InterstitialData>[] = [
    {
      label: 'Title',
      property: 'title',
      type: FilterTypes.FreeText,
    },
    {
      label: 'External ID',
      property: 'externalId',
      type: FilterTypes.FreeText,
    },
  ];

  const transformFilters = (
    filters: FilterValues<InterstitialData>,
    excludeItems?: number[],
  ): InterstitialFilter | undefined => {
    return filterToPostGraphileFilter<InterstitialFilter>(filters, {
      title: 'includesInsensitive',
      externalId: 'includesInsensitive',
    });
  };

  return { filterOptions, transformFilters };
}
