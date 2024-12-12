import React from 'react';
import { InterstitialExplorer } from './InterstitialExplorer';
export const Interstitials: React.FC = () => {
  return (
    <InterstitialExplorer
      title="Interstitials"
      stationKey="InterstitialsExplorer"
      kind="NavigationExplorer"
      calculateNavigateUrl={(item) => `/interstitials/${item.id}`}
      onCreateAction="/interstitials/create"
    />
  );
};
