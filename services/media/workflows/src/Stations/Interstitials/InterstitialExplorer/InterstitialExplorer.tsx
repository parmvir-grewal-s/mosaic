import {
  Column,
  DateRenderer,
  ExplorerDataProvider,
  NavigationExplorer,
  SelectionExplorer,
  sortToPostGraphileOrderBy,
} from '@axinom/mosaic-ui';
import React from 'react';
import { useHistory } from 'react-router-dom';
import { client } from '../../../apolloClient';
import {
  InterstitialsDocument,
  InterstitialsOrderBy,
  InterstitialsQuery,
  InterstitialsQueryVariables,
} from '../../../generated/graphql';
import { useInterstitialsFilters } from './InterstitialExplorer.filters';
import { InterstitialExplorerProps } from './InterstitialExplorer.types';

type InterstitialData = NonNullable<
  InterstitialsQuery['filtered']
>['nodes'][number];

export const InterstitialExplorer: React.FC<InterstitialExplorerProps> = (
  props,
) => {
  const { transformFilters, filterOptions } = useInterstitialsFilters();
  const history = useHistory();
  // Columns
  const explorerColumns: Column<InterstitialData>[] = [
    { label: 'Title', propertyName: 'title' },
    { label: 'External ID', propertyName: 'externalId' },
    { label: 'Created At', propertyName: 'createdDate', render: DateRenderer },
    { label: 'Updated At', propertyName: 'updatedDate', render: DateRenderer },
  ];

  // Data provider
  const dataProvider: ExplorerDataProvider<InterstitialData> = {
    loadData: async ({ pagingInformation, sorting, filters }) => {
      let filterWithExclusions = filters;

      if (props.excludeItems) {
        filterWithExclusions = { id: props.excludeItems, ...filters };
      }

      const result = await client.query<
        InterstitialsQuery,
        InterstitialsQueryVariables
      >({
        query: InterstitialsDocument,
        variables: {
          filter: transformFilters(filterWithExclusions, props.excludeItems),
          orderBy: sortToPostGraphileOrderBy(sorting, InterstitialsOrderBy),
          after: pagingInformation,
        },
        fetchPolicy: 'network-only',
      });

      return {
        data: result.data.filtered?.nodes ?? [],
        totalCount: result.data.nonFiltered?.totalCount as number,
        filteredCount: result.data.filtered?.totalCount as number,
        hasMoreData: result.data.filtered?.pageInfo.hasNextPage || false,
        pagingInformation: result.data.filtered?.pageInfo.endCursor,
      };
    },
  };

  switch (props.kind) {
    case 'NavigationExplorer':
      return (
        <NavigationExplorer<InterstitialData>
          {...props}
          columns={explorerColumns}
          dataProvider={dataProvider}
          defaultSortOrder={{ column: 'updatedDate', direction: 'desc' }}
        />
      );
    case 'SelectionExplorer':
      return (
        <SelectionExplorer<InterstitialData>
          {...props}
          columns={explorerColumns}
          dataProvider={dataProvider}
          defaultSortOrder={{ column: 'updatedDate', direction: 'desc' }}
          generateItemLink={(item) => `/interstitials/${item.id}`}
        />
      );
    default:
      return <div>Explorer type is not defined</div>;
  }
};
