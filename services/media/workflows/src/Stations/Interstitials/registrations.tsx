import { PiletApi } from '@axinom/mosaic-portal';
import React from 'react';
import { Extensions } from '../../externals';

export function register(app: PiletApi, extensions: Extensions): void {
  app.registerTile({
    kind: 'home',
    name: 'interstitials',
    path: '/interstitials',
    label: 'Interstitials',
    icon: (
      <svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40">
        <path
          vectorEffect="non-scaling-stroke"
          fill="none"
          stroke="#00467D"
          strokeWidth="2"
          d="M10.3,33.5h19.5 M1,21.9c9.9-2.7,10.5-15.4,10.5-15.4 M7.8,31.1
	c0,0,0.8-6.1-4.3-10.2 M16,14.7V25l9.4-5.2L16,14.7z M28.8,6.5c0,0,0.6,12.7,10.2,15.4 M36.5,21c-4.8,4-4.2,10.2-4.2,10.2 M39,6.5H1
	V31h38V6.5z"
        />
      </svg>
    ),
    type: 'large',
  });
}
