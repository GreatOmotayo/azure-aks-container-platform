const { QueueClient } = require('@azure/storage-queue');
const { DefaultAzureCredential } = require('@azure/identity');

const ACCOUNT_NAME = process.env.STORAGE_ACCOUNT_NAME;
const QUEUE_NAME = 'jobs';

const credential = new DefaultAzureCredential();

const queueClient = new QueueClient(
  `https://${ACCOUNT_NAME}.queue.core.windows.net/${QUEUE_NAME}`,
  credential
);

async function enqueueJob(jobId) {
  const encoded = Buffer.from(jobId, 'utf-8').toString('base64');
  await queueClient.sendMessage(encoded);
}

module.exports = { enqueueJob };