import { LocalizationServiceMessagingSettings } from '@axinom/mosaic-messages';
import { MosaicError } from '@axinom/mosaic-service-common';
import {
  ChannelLocalization,
  ChannelPublishedEvent,
  DetailedVideo,
} from 'media-messages';
import Hasher from 'node-object-hash';
import { ClientBase } from 'pg';
import { v4 as uuid } from 'uuid';
import { select } from 'zapatos/db';
import {
  CommonErrors,
  Config,
  isManagedServiceEnabled,
  LOCALIZATION_CHANNEL_TYPE,
} from '../../../common';
import { getValidationAndImages } from '../../../publishing/common';
import {
  getChannelValidationAndLocalizations,
  getDefaultChannelLocalization,
} from '../../../publishing/common/localization';
import {
  calculateValidationStatus,
  PublishValidationMessage,
  PublishValidationResult,
} from '../../../publishing/models';
import { aggregateChannelPublishDto } from './aggregate-channel-publish-dto';
import { createChannelPublishPayload } from './create-channel-publish-payload';

const hasher = Hasher();

export async function validateChannel(
  id: string,
  jwtToken: string,
  gqlClient: ClientBase,
  config: Config,
): Promise<PublishValidationResult<ChannelPublishedEvent>> {
  const validations: PublishValidationMessage[] = [];
  const publishDto = await aggregateChannelPublishDto(id, gqlClient);

  if (publishDto === undefined) {
    throw new MosaicError({
      ...CommonErrors.ChannelNotFound,
      details: { channelId: id },
    });
  }

  const image_rows = await select(
    'channel_images',
    { channel_id: id },
    { columns: ['image_id'] },
  ).run(gqlClient);

  const [
    { images, validations: imageValidations },
    isLocalizationServiceEnabled,
  ] = await Promise.all([
    getValidationAndImages(
      config.imageServiceBaseUrl,
      jwtToken,
      image_rows.map((ci) => ci.image_id),
      true,
    ),
    isManagedServiceEnabled(
      LocalizationServiceMessagingSettings.LocalizationServiceEnable.serviceId,
      config,
      jwtToken,
      false,
    ),
  ]);

  validations.push(...imageValidations);

  let localizationsToPublish: ChannelLocalization[];
  // Skip requests to the localization service if it is not enabled for the environment
  if (isLocalizationServiceEnabled && config.isLocalizationEnabled) {
    const { localizations, validations: localizationValidations } =
      await getChannelValidationAndLocalizations(
        config.localizationServiceBaseUrl,
        jwtToken,
        id,
        LOCALIZATION_CHANNEL_TYPE,
        config.serviceId,
      );
    localizationsToPublish = localizations ?? [];
    validations.push(...localizationValidations);
  } else {
    localizationsToPublish = [
      getDefaultChannelLocalization(publishDto.title, publishDto.description),
    ];
  }

  // transform the dto to a publish message
  const publishPayload = createChannelPublishPayload(
    publishDto,
    images,
    createVideo() ?? undefined,
    localizationsToPublish,
  );

  const validationStatus = calculateValidationStatus(validations);
  const publishHash = hasher.hash(publishPayload);

  return {
    publishPayload,
    validations,
    publishHash,
    validationStatus,
  };
}

export const createVideo = (): DetailedVideo => {
  const videoId = uuid();
  return {
    id: videoId,
    custom_id: 'custom_id',
    title: `Video ${videoId}`,
    source_location: `source/folder/video-${videoId}`,
    is_archived: false,
    videos_tags: [videoId, 'video', 'channel'],
    video_encoding: {
      is_protected: false,
      encoding_state: 'READY',
      output_format: 'CMAF',
      preview_status: 'APPROVED',
      audio_languages: [],
      caption_languages: [],
      subtitle_languages: [],
      video_streams: [
        {
          label: 'audio',
          file: 'audio.mp4',
          format: 'CMAF',
        },
        {
          label: 'SD',
          file: 'video.mp4',
          format: 'CMAF',
        },
      ],
    },
  };
};
