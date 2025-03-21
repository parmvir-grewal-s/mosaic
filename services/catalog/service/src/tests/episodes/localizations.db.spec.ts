import gql from 'graphql-tag';
import 'jest-extended';
import { insert } from 'zapatos/db';
import {
  DEFAULT_LOCALE_TAG,
  MOSAIC_LOCALE_HEADER_KEY,
  syncInMemoryLocales,
} from '../../common';
import { createTestContext, ITestContext } from '../test-utils';

const EPISODE_REQUEST = gql`
  query EpisodeLocalization {
    episodes {
      nodes {
        description
        synopsis
        title
      }
    }
  }
`;

describe('Episode Localization Graphql Requests', () => {
  let ctx: ITestContext;
  const episodeId = 'episode-1';

  beforeAll(async () => {
    ctx = await createTestContext();
    await insert('episode', { id: episodeId }).run(ctx.ownerPool);
    await syncInMemoryLocales(
      [
        { language_tag: DEFAULT_LOCALE_TAG, is_default_locale: true },
        { language_tag: 'de-DE', is_default_locale: false },
        { language_tag: 'et-EE', is_default_locale: false },
      ],
      ctx.ownerPool,
    );
  });

  beforeEach(async () => {
    await insert('episode_localizations', {
      episode_id: episodeId,
      title: 'Default title',
      description: 'Default description',
      synopsis: 'Default synopsis',
      locale: DEFAULT_LOCALE_TAG,
      is_default_locale: true,
    }).run(ctx.ownerPool);
  });

  afterEach(async () => {
    await ctx?.truncate('episode_localizations');
  });

  afterAll(async () => {
    await ctx?.truncate('episode');
    await ctx?.dispose();
  });

  const getRequestContext = (locale: string) => {
    return {
      headers: {
        [MOSAIC_LOCALE_HEADER_KEY]: locale,
      },
    };
  };

  it('Episode with only default localization and empty filter -> default localization returned', async () => {
    // Act
    const resp = await ctx.runGqlQuery(
      EPISODE_REQUEST,
      {},
      getRequestContext(''),
    );

    // Assert
    expect(resp.errors).toBeFalsy();

    expect(resp?.data?.episodes.nodes).toEqual([
      {
        title: 'Default title',
        synopsis: 'Default synopsis',
        description: 'Default description',
      },
    ]);
  });

  it('Episode with 2 localizations and empty filter -> default localization returned', async () => {
    // Arrange
    await insert('episode_localizations', {
      episode_id: episodeId,
      title: 'Localized title',
      synopsis: 'Localized synopsis',
      description: 'Localized description',
      locale: 'de-DE',
      is_default_locale: false,
    }).run(ctx.ownerPool);

    // Act
    const resp = await ctx.runGqlQuery(
      EPISODE_REQUEST,
      {},
      getRequestContext(''),
    );

    // Assert
    expect(resp.errors).toBeFalsy();

    expect(resp?.data?.episodes.nodes).toEqual([
      {
        title: 'Default title',
        synopsis: 'Default synopsis',
        description: 'Default description',
      },
    ]);
  });

  it('Episode with 2 localizations and no filter -> default localization returned', async () => {
    // Arrange
    await insert('episode_localizations', {
      episode_id: episodeId,
      title: 'Localized title',
      synopsis: 'Localized synopsis',
      description: 'Localized description',
      locale: 'de-DE',
      is_default_locale: false,
    }).run(ctx.ownerPool);

    // Act
    const resp = await ctx.runGqlQuery(EPISODE_REQUEST);

    // Assert
    expect(resp.errors).toBeFalsy();

    expect(resp?.data?.episodes.nodes).toEqual([
      {
        title: 'Default title',
        synopsis: 'Default synopsis',
        description: 'Default description',
      },
    ]);
  });

  it('Episode with 3 localizations and valid filter -> selected non-default localization returned', async () => {
    // Arrange
    await insert('episode_localizations', [
      {
        episode_id: episodeId,
        title: 'Localized title',
        synopsis: 'Localized synopsis',
        description: 'Localized description',
        locale: 'de-DE',
        is_default_locale: false,
      },
      {
        episode_id: episodeId,
        title: 'Localized title 2',
        synopsis: 'Localized synopsis 2',
        description: 'Localized description 2',
        locale: 'et-EE',
        is_default_locale: false,
      },
    ]).run(ctx.ownerPool);

    // Act
    const resp = await ctx.runGqlQuery(
      EPISODE_REQUEST,
      {},
      getRequestContext('de-DE'),
    );

    // Assert
    expect(resp.errors).toBeFalsy();

    expect(resp?.data?.episodes.nodes).toEqual([
      {
        title: 'Localized title',
        synopsis: 'Localized synopsis',
        description: 'Localized description',
      },
    ]);
  });

  it('Episode with 3 localizations and non-existent locale filter -> default localization returned', async () => {
    // Arrange
    await insert('episode_localizations', [
      {
        episode_id: episodeId,
        title: 'Localized title',
        synopsis: 'Localized synopsis',
        description: 'Localized description',
        locale: 'de-DE',
        is_default_locale: false,
      },
      {
        episode_id: episodeId,
        title: 'Localized title 2',
        synopsis: 'Localized synopsis 2',
        description: 'Localized description 2',
        locale: 'et-EE',
        is_default_locale: false,
      },
    ]).run(ctx.ownerPool);

    // Act
    const resp = await ctx.runGqlQuery(
      EPISODE_REQUEST,
      {},
      getRequestContext('asdf'),
    );

    // Assert
    expect(resp.errors).toBeFalsy();

    expect(resp?.data?.episodes.nodes).toEqual([
      {
        title: 'Default title',
        synopsis: 'Default synopsis',
        description: 'Default description',
      },
    ]);
  });
});
