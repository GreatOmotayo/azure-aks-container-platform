const http = require('http');
const crypto = require('crypto');
const { receiveJob, deleteJobMessage } = require('./lib/queueClient');
const { updateJobStatus, isTableStorageReachable } = require('./lib/tableClient');

const HEALTH_PORT = process.env.HEALTH_PORT || 3001;
const POLL_INTERVAL_MS = 2000;

let isShuttingDown = false;

const healthServer = http.createServer(async (req, res) => {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok' }));
    return;
  }

  if (req.url === '/ready') {
    const reachable = await isTableStorageReachable();
    res.writeHead(reachable ? 200 : 503, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: reachable ? 'ready' : 'not ready' }));
    return;
  }

  res.writeHead(404);
  res.end();
});

healthServer.listen(HEALTH_PORT, () => {
  console.log(`Worker health server listening on port ${HEALTH_PORT}`);
});

async function simulateCpuBoundWork() {
  const durationMs = 5000 + Math.floor(Math.random() * 15000);
  const start = Date.now();
  let hash = 'seed';
  let lastYield = start;

  while (Date.now() - start < durationMs) {
    hash = crypto.createHash('sha256').update(hash).digest('hex');

    if (Date.now() - lastYield > 200) {
      await new Promise((resolve) => setImmediate(resolve));
      lastYield = Date.now();
    }
  }

  return { durationMs, finalHash: hash };
}

async function pollLoop() {
  while (!isShuttingDown) {
    let job;

    try {
      job = await receiveJob();
    } catch (err) {
      console.error('Failed to receive from queue:', err.message);
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    if (!job) {
      await sleep(POLL_INTERVAL_MS);
      continue;
    }

    console.log(`Processing job ${job.jobId}`);

    try {
      const { durationMs, finalHash } = await simulateCpuBoundWork();
      await updateJobStatus(job.jobId, 'done', `completed in ${durationMs}ms, hash=${finalHash}`);
      await deleteJobMessage(job.messageId, job.popReceipt);
      console.log(`Job ${job.jobId} completed and message deleted`);
    } catch (err) {
      console.error(`Job ${job.jobId} failed, message will retry after visibility timeout:`, err.message);
    }
  }

  console.log('Poll loop stopped - shutting down cleanly');
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

process.on('SIGTERM', () => {
  console.log('SIGTERM received, finishing current iteration before exit');
  isShuttingDown = true;
});

pollLoop();