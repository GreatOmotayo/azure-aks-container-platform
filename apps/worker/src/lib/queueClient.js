const { QueueClient } = require('@azure/storage-queue');
const { DefaultAzureCredential } = require('@azure/identity');

const ACCOUNT_NAME = process.env.STORAGE_ACCOUNT_NAME;
const QUEUE_NAME = 'jobs';

const VISIBILITY_TIMEOUT_SECONDS = 60;

const credential = new DefaultAzureCredential();

const queueClient = new QueueClient(
  `https://${ACCOUNT_NAME}.queue.core.windows.net/${QUEUE_NAME}`,
  credential
);

async function receiveJob() {
  const response = await queueClient.receiveMessages({
    numberOfMessages: 1,
    visibilityTimeout: VISIBILITY_TIMEOUT_SECONDS,
  });

  if (response.receivedMessageItems.length === 0) {
    return null;
  }

  const msg = response.receivedMessageItems[0];
  const jobId = Buffer.from(msg.messageText, 'base64').toString('utf-8');

  return {
    jobId,
    messageId: msg.messageId,
    popReceipt: msg.popReceipt,
  };
}

async function deleteJobMessage(messageId, popReceipt) {
  await queueClient.deleteMessage(messageId, popReceipt);
}

module.exports = { receiveJob, deleteJobMessage };