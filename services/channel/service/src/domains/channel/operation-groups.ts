import {
  Mutations as M,
  Queries as Q,
  Subscriptions as S,
} from '../../generated/graphql/operations';

export const ChannelsReadOperations = [
  Q.channel,
  Q.channelImage,
  Q.channelImages,
  Q.channels,
  Q.cuePointSchedule,
  Q.cuePointSchedules,
  Q.playlist,
  Q.playlists,
  Q.program,
  Q.programCuePoint,
  Q.programCuePoints,
  Q.programs,
  Q.validateChannel,
  Q.validatePlaylist,
  S.channelMutated,
  S.playlistMutated,
];

export const ChannelsMutateOperations = [
  M.createAdCuePointSchedule,
  M.createChannel,
  M.createChannelImage,
  M.createPlaylist,
  M.createProgram,
  M.createProgramCuePoint,
  M.createVideoCuePointSchedule,
  M.deleteChannel,
  M.deleteChannelImage,
  M.deleteChannelImageByIds,
  M.deleteCuePointSchedule,
  M.deletePlaylist,
  M.deleteProgram,
  M.deleteProgramCuePoint,
  M.publishChannel,
  M.publishPlaylist,
  M.unpublishChannel,
  M.unpublishPlaylist,
  M.updateAdCuePointSchedule,
  M.updateChannel,
  M.updateChannelImage,
  M.updateChannelImageByIds,
  M.updatePlaylist,
  M.updateProgram,
  M.updateProgramCuePoint,
  M.updateVideoCuePointSchedule,
];

export const ChannelIgnoreOperations = [];
