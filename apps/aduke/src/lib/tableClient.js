const { TableClient } = require('@azure/data-tables');
const { DefaultAzureCredential } = require('@azure/identity');

const ACCOUNT_NAME = process.env.STORAGE_ACCOUNT_NAME;
const TABLE_NAME = 'jobs';

const credential = new DefaultAzureCredential();

const tableClient = new TableClient(
  `https://${ACCOUNT_NAME}.table.core.windows.net`,
  TABLE_NAME,
  credential
);

async function isTableStorageReachable() {
  try {
    const iterator = tableClient.listEntities({ queryOptions: { top: 1 } });
    await iterator.next();
    return true;
  } catch (err) {
    console.error('Table Storage readiness check failed:', err.message);
    return false;
  }
}

async function createJob(jobId) {
  await tableClient.createEntity({
    partitionKey: 'job',
    rowKey: jobId,
    status: 'queued',
    result: '',
    createdAt: new Date().toISOString(),
  });
}

async function getJob(jobId) {
  try {
    return await tableClient.getEntity('job', jobId);
  } catch (err) {
    if (err.statusCode === 404) return null;
    throw err;
  }
}

module.exports = { isTableStorageReachable, createJob, getJob, tableClient };