import {
  NavigationExplorerProps,
  SelectionExplorerProps,
} from '@axinom/mosaic-ui';
import { InterstitialsQuery } from '../../../generated/graphql';

export type InterstitialData = NonNullable<
  InterstitialsQuery['filtered']
>['nodes'][number];

interface Props {
  excludeItems?: InterstitialData['id'][];
}

export interface InterstitialSelectionExplorerProps
  extends Omit<
      SelectionExplorerProps<InterstitialData>,
      'columns' | 'dataProvider' | 'filterOptions'
    >,
    Props {
  /** Type Tag */
  kind: 'SelectionExplorer';
}

export interface InterstitialNavigationExplorerProps
  extends Omit<
      NavigationExplorerProps<InterstitialData>,
      'columns' | 'dataProvider' | 'filterOptions'
    >,
    Props {
  /** Type Tag */
  kind: 'NavigationExplorer';
}

export type InterstitialExplorerProps =
  | InterstitialSelectionExplorerProps
  | InterstitialNavigationExplorerProps;
