import {
  createUpdateGQLFragmentGenerator,
  Details,
  DetailsProps,
  generateArrayMutations,
} from '@axinom/mosaic-ui';
import { Field } from 'formik';
import gql from 'graphql-tag';
import { ObjectSchemaDefinition } from 'ObjectSchemaDefinition';
import React, { useCallback } from 'react';
import * as Yup from 'yup';
import { client } from '../../../apolloClient';
import {
  Mutation,
  MutationUpdateEpisodeArgs,
  useSeasonEpisodesQuery,
} from '../../../generated/graphql';
import { EpisodeSelectField } from './EpisodeSelectField/EpisodeSelectField';
import { SeasonEpisode } from './SeasonEpisodeManagement.types';

interface SeasonEpisodeManagementFormProps {
  seasonId: number;
}

interface FormData {
  episodes: SeasonEpisode[];
}

const seasonEpisodeManagementSchema = Yup.object().shape<
  ObjectSchemaDefinition<FormData>
>({
  episodes: Yup.array().of(Yup.object()),
});

export const SeasonEpisodeManagementForm: React.FC<
  SeasonEpisodeManagementFormProps
> = ({ seasonId }) => {
  const { loading, data, error } = useSeasonEpisodesQuery({
    client,
    variables: { id: seasonId },
    fetchPolicy: 'no-cache',
  });

  const onSubmit = useCallback(
    async (
      formData: FormData,
      initialData: DetailsProps<FormData>['initialData'],
    ): Promise<void> => {
      const generateUpdateGQLFragment =
        createUpdateGQLFragmentGenerator<Mutation>();

      const episodeAssignmentMutations = generateArrayMutations({
        current: formData.episodes,
        original: initialData.data?.episodes,
        generateCreateMutation: ({ id }) =>
          generateUpdateGQLFragment<MutationUpdateEpisodeArgs>(
            'updateEpisode',
            { input: { id, patch: { seasonId: seasonId } } },
          ),
        generateDeleteMutation: ({ id }) =>
          generateUpdateGQLFragment<MutationUpdateEpisodeArgs>(
            'updateEpisode',
            { input: { id, patch: { seasonId: null } } },
          ),
      });

      const GqlMutationDocument = gql`mutation UpdateSeasonEpisodes {
        ${episodeAssignmentMutations}
      }`;

      await client.mutate({ mutation: GqlMutationDocument });
    },
    [seasonId],
  );

  return (
    <Details<FormData>
      defaultTitle="Episode Management"
      validationSchema={seasonEpisodeManagementSchema}
      initialData={{
        data: {
          episodes: data?.season?.episodes.nodes ?? [],
        },
        loading,
        entityNotFound: data?.season === null,
        error: error?.message,
      }}
      saveData={onSubmit}
    >
      <Form />
    </Details>
  );
};

const Form: React.FC = () => {
  return (
    <>
      <Field name="episodes" label="Episodes" as={EpisodeSelectField} />
    </>
  );
};
