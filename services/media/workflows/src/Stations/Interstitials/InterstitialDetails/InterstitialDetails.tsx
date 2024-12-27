import {
  Details,
  DetailsProps,
  getFormDiff,
  IconName,
  Nullable,
  SingleLineTextField,
} from '@axinom/mosaic-ui';
import { Field } from 'formik';
import { ObjectSchemaDefinition } from 'ObjectSchemaDefinition';
import React, { useCallback } from 'react';
import { useHistory, useParams } from 'react-router-dom';
import { object, string } from 'yup';
import { client } from '../../../apolloClient';
import {
  MutationUpdateInterstitialArgs,
  useDeleteInterstitialMutation,
  useInterstitialQuery,
  useUpdateInterstitialMutation,
} from '../../../generated/graphql';

type FormData = Nullable<MutationUpdateInterstitialArgs['input']['patch']>;

const interstitialDetailSchema = object<ObjectSchemaDefinition<FormData>>({
  title: string().required('Title is a required field').max(100),
  externalId: string().max(100),
});

export const InterstitialDetails: React.FC = () => {
  const interstitialId = Number(
    useParams<{
      interstitialId: string;
    }>().interstitialId,
  );

  const { loading, data, error } = useInterstitialQuery({
    client,
    variables: { id: interstitialId },
    fetchPolicy: 'no-cache',
  });

  const [updateInterstitial] = useUpdateInterstitialMutation({
    client,
    fetchPolicy: 'no-cache',
  });

  const onSubmit = useCallback(
    async (
      formData: FormData,
      initialData: DetailsProps<FormData>['initialData'],
    ): Promise<void> => {
      await updateInterstitial({
        variables: {
          input: {
            id: interstitialId,
            patch: getFormDiff(formData, initialData.data),
          },
        },
      });
    },
    [interstitialId, updateInterstitial],
  );

  const history = useHistory();
  const [deleteInterstitialMutation] = useDeleteInterstitialMutation({
    client,
    fetchPolicy: 'no-cache',
  });
  const deleteInterstitial = async (): Promise<void> => {
    await deleteInterstitialMutation({
      variables: { input: { id: interstitialId } },
    });
    history.push('/interstitials');
  };

  return (
    <Details<FormData>
      defaultTitle="Interstitial"
      titleProperty="title"
      subtitle="Properties"
      validationSchema={interstitialDetailSchema}
      initialData={{
        data: data?.interstitial,
        loading,
        error: error?.message,
      }}
      saveData={onSubmit}
      actions={[
        {
          label: 'Delete',
          icon: IconName.Delete,
          confirmationMode: 'Simple',
          onActionSelected: deleteInterstitial,
        },
      ]}
    >
      <Form />
    </Details>
  );
};

const Form: React.FC = () => {
  return (
    <>
      <Field name="title" label="Title" as={SingleLineTextField} />
      <Field name="externalId" label="External ID" as={SingleLineTextField} />
      <Field name="duration" label="Duration" as={SingleLineTextField} />
    </>
  );
};
