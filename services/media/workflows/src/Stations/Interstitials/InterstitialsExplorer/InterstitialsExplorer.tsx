import {
  Column,
  DateRenderer,
  ExplorerDataProvider,
  NavigationExplorer,
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

type InterstitialData = NonNullable<
  InterstitialsQuery['filtered']
>['nodes'][number];

export const InterstitialsExplorer: React.FC = () => {
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
    loadData: async ({ pagingInformation, sorting }) => {
      const result = await client.query<
        InterstitialsQuery,
        InterstitialsQueryVariables
      >({
        query: InterstitialsDocument,
        variables: {
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

  return (
    <NavigationExplorer<InterstitialData>
      title="Interstitials"
      stationKey="InterstitialsExplorer"
      columns={explorerColumns}
      dataProvider={dataProvider}
      onCreateAction={() => {
        history.push(`/interstitials/create`);
      }}
      calculateNavigateUrl={({ id }) => {
        return `/interstitials/${id}`;
      }}
    />
  );
};
