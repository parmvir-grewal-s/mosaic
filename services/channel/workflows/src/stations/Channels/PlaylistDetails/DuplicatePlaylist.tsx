import {
  ActionHandler,
  Create,
  DateTimeTextField,
  ObjectSchemaDefinition,
} from '@axinom/mosaic-ui';
import { Field } from 'formik';
import React, { useCallback } from 'react';
import { useHistory, useParams } from 'react-router-dom';
import * as Yup from 'yup';
import { client } from '../../../apolloClient';
import {
  DuplicatePlaylistMutation,
  useDuplicatePlaylistMutation,
} from '../../../generated/graphql';
import { routes } from '../routes';

interface FormData {
  startDateTime: string; // Single DateTime input from users
}

type SubmitResponse =
  | DuplicatePlaylistMutation['duplicatePlaylist']
  | undefined;

const duplicatePlaylistSchema = Yup.object().shape<
  ObjectSchemaDefinition<FormData>
>({
  startDateTime: Yup.date().required('Start date and time is required.'),
});

export const DuplicatePlaylist: React.FC = () => {
  const { playlistId } = useParams<{
    playlistId: string;
  }>();

  const channelId = useParams<{
    channelId: string;
  }>().channelId;

  const [duplicatePlaylist] = useDuplicatePlaylistMutation({
    client: client,
    fetchPolicy: 'no-cache',
  });

  const saveData = useCallback(
    async (formData: FormData): Promise<SubmitResponse> => {
      const [startDate, startTime] = formData.startDateTime.split('T'); // Split into date and time
      return (
        await duplicatePlaylist({
          variables: {
            input: {
              playlistId: playlistId,
              startDate: startDate,
              startTime: startTime,
            },
          },
        })
      ).data?.duplicatePlaylist;
    },
    [duplicatePlaylist, playlistId],
  );

  const history = useHistory();
  const onProceed = useCallback<ActionHandler<FormData, SubmitResponse>>(
    ({ submitResponse }) => {
      if (submitResponse?.newPlaylistId) {
        history.push(
          routes.generate(routes.playlistDetails, {
            channelId,
            playlistId: submitResponse.newPlaylistId,
          }),
        );
      } else {
        throw new Error('Not expected');
      }
    },
    [history, channelId],
  );

  return (
    <Create<FormData, SubmitResponse>
      title="Duplicate Playlist"
      subtitle="Duplicate this playlist with a new start date and time"
      validationSchema={duplicatePlaylistSchema}
      saveData={saveData}
      onProceed={onProceed}
      cancelNavigationUrl="./"
      initialData={{
        loading: false,
      }}
    >
      <Field
        name="startDateTime"
        label="New Scheduled Start"
        as={DateTimeTextField}
      />
    </Create>
  );
};
