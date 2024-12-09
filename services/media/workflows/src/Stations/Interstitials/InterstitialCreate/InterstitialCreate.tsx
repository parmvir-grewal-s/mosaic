import { ActionHandler, Create, SingleLineTextField } from '@axinom/mosaic-ui';
import { Field } from 'formik';
import { ObjectSchemaDefinition } from 'ObjectSchemaDefinition';
import React, { useCallback } from 'react';
import { useHistory } from 'react-router-dom';
import { object, string } from 'yup';
import { client } from '../../../apolloClient';
import {
  CreateInterstitialMutation,
  CreateInterstitialMutationVariables,
  useCreateInterstitialMutation,
} from '../../../generated/graphql';

type FormData = CreateInterstitialMutationVariables['input']['interstitial'];

type SubmitResponse = CreateInterstitialMutation['createInterstitial'];

const interstitialCreateSchema = object().shape<
  ObjectSchemaDefinition<FormData>
>({
  title: string().required('Title is a required field').max(100),
  externalId: string().max(100),
});

export const InterstitialCreate: React.FC = () => {
  const [interstitialCreate] = useCreateInterstitialMutation({
    client: client,
    fetchPolicy: 'no-cache',
  });

  const saveData = useCallback(
    async (formData: FormData): Promise<SubmitResponse> => {
      return (
        await interstitialCreate({
          variables: {
            input: {
              interstitial: {
                title: formData.title,
                externalId: formData.externalId,
              },
            },
          },
        })
      ).data?.createInterstitial;
    },
    [interstitialCreate],
  );

  const history = useHistory();
  const onProceed = useCallback<ActionHandler<FormData, SubmitResponse>>(
    ({ submitResponse }) => {
      history.push(`/interstitials/${submitResponse?.interstitial?.id}`);
    },
    [history],
  );

  return (
    <Create<FormData, SubmitResponse>
      title="New Interstitial"
      subtitle="Add new interstitial metadata"
      validationSchema={interstitialCreateSchema}
      saveData={saveData}
      onProceed={onProceed}
      cancelNavigationUrl="/interstitials"
      initialData={{
        loading: false,
      }}
    >
      <Field name="title" label="Title" as={SingleLineTextField} />
      <Field name="externalId" label="External ID" as={SingleLineTextField} />
    </Create>
  );
};
