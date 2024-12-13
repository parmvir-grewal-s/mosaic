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
    {
      label: 'ID',
      property: 'id',
      type: FilterTypes.Numeric,
    },
  ];

  const transformFilters = (
    filters: FilterValues<InterstitialData>,
    excludeItems?: number[],
  ): InterstitialFilter | undefined => {
    return filterToPostGraphileFilter<InterstitialFilter>(filters, {
      title: 'includesInsensitive',
      externalId: 'includesInsensitive',
      id: (value) => {
        if (typeof value === 'number') {
          // User filter
          return {
            equalTo: value,
            notIn: excludeItems,
          };
        } else {
          // Exclude items
          return {
            notIn: excludeItems,
          };
        }
      },
    });
  };

  return { filterOptions, transformFilters };
}
