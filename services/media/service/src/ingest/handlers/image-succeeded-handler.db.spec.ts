import { AuthenticatedManagementSubject } from '@axinom/mosaic-id-guard';
import { EnsureImageExistsImageCreatedEvent } from '@axinom/mosaic-messages';
import { MosaicError } from '@axinom/mosaic-service-common';
import { TypedTransactionalMessage } from '@axinom/mosaic-transactional-inbox-outbox';
import { stub } from 'jest-auto-stub';
import 'jest-extended';
import { v4 as uuid } from 'uuid';
import { insert, selectOne } from 'zapatos/db';
import {
  ingest_documents,
  ingest_items,
  ingest_item_steps,
} from 'zapatos/schema';
import { CommonErrors } from '../../common';
import { MockIngestProcessor } from '../../tests/ingest/mock-ingest-processor';
import {
  createTestContext,
  createTestUser,
  ITestContext,
} from '../../tests/test-utils';
import { ImageCreatedHandler } from './image-created-handler';

// These tests cover logic for both ImageAlreadyExisted and ImageCreated handlers
describe('ImageSucceededHandler', () => {
  let ctx: ITestContext;
  let user: AuthenticatedManagementSubject;
  let handler: ImageCreatedHandler;
  let step1: ingest_item_steps.JSONSelectable;
  let item1: ingest_items.JSONSelectable;
  let doc1: ingest_documents.JSONSelectable;

  const createMessage = (
    payload: EnsureImageExistsImageCreatedEvent,
    messageContext: unknown,
  ) =>
    stub<TypedTransactionalMessage<EnsureImageExistsImageCreatedEvent>>({
      payload,
      metadata: {
        messageContext,
      },
    });

  beforeAll(async () => {
    ctx = await createTestContext();
    user = createTestUser(ctx.config.serviceId);
    handler = new ImageCreatedHandler([new MockIngestProcessor()], ctx.config);
  });

  beforeEach(async () => {
    doc1 = await insert('ingest_documents', {
      name: 'test1',
      title: 'test1',
      document: {
        name: 'test1',
        document_created: '2020-08-04T08:57:40.763+00:00',
        items: [],
      },
      items_count: 0,
    }).run(ctx.ownerPool);
    item1 = await insert('ingest_items', {
      ingest_document_id: doc1.id,
      external_id: 'externalId',
      entity_id: 1,
      type: 'MOVIE',
      exists_status: 'CREATED',
      display_title: 'title',
      item: {
        type: 'MOVIE',
        external_id: 'externalId',
        data: {
          title: 'title',
          trailers: [{ source: 'test', profile: 'DEFAULT' }],
        },
      },
    }).run(ctx.ownerPool);
    step1 = await insert('ingest_item_steps', {
      id: uuid(),
      type: 'IMAGE',
      ingest_item_id: item1.id,
      sub_type: 'COVER',
    }).run(ctx.ownerPool);
  });

  afterEach(async () => {
    await ctx.truncate('ingest_documents');
  });

  afterAll(async () => {
    await ctx.dispose();
    jest.restoreAllMocks();
  });

  describe('handleMessage', () => {
    it('message succeeded without errors -> step updated', async () => {
      // Arrange
      const payload: EnsureImageExistsImageCreatedEvent = {
        image_id: '11e1d903-49ed-4d70-8b24-90d0824741d0',
      };
      const metadata = {
        ingestItemStepId: step1.id,
        ingestItemId: item1.id,
        imageType: 'COVER',
      };

      // Act
      await ctx.executeOwnerSql(user, async (dbCtx) =>
        handler.handleMessage(createMessage(payload, metadata), dbCtx),
      );

      // Assert
      const step = await selectOne('ingest_item_steps', {
        id: step1.id,
      }).run(ctx.ownerPool);

      expect(step?.entity_id).toEqual(payload.image_id);
      expect(step?.status).toEqual('SUCCESS');
    });
  });

  describe('mapError', () => {
    it('message failed with non-mosaic error -> default error mapped', async () => {
      // Act
      const error = handler.mapError(new Error('Unexpected status code: 404'));

      // Assert
      expect(error).toMatchObject({
        message:
          'The image was correctly imported, but there was an error adding that image to the entity.',
        code: CommonErrors.IngestError.code,
      });
    });

    it('message failed with mosaic error -> thrown error mapped', async () => {
      // Arrange
      const testErrorInfo = {
        message: 'Handled test message',
        code: 'HANDLED_TEST_CODE',
      };

      // Act
      const error = handler.mapError(new MosaicError(testErrorInfo));

      // Assert
      expect(error).toMatchObject(testErrorInfo);
    });
  });

  describe('handleErrorMessage', () => {
    it('message failed on all retries -> step updated', async () => {
      // Arrange
      const payload: EnsureImageExistsImageCreatedEvent = {
        image_id: '11e1d903-49ed-4d70-8b24-90d0824741d0',
      };
      const context = {
        ingestItemStepId: step1.id,
        ingestItemId: item1.id,
        imageType: 'COVER',
      };
      // mapError makes sure this error is appropriate
      const error = new Error('Handled and mapped message');

      // Act
      await ctx.executeOwnerSql(user, async (dbCtx) =>
        handler.handleErrorMessage(
          // mapError makes sure this error is appropriate
          error,
          createMessage(payload, context),
          dbCtx,
          false,
        ),
      );

      // Assert
      const step = await selectOne('ingest_item_steps', {
        id: step1.id,
      }).run(ctx.ownerPool);
      expect(step?.response_message).toEqual(error.message);
      expect(step?.status).toEqual('ERROR');
    });
  });
});
