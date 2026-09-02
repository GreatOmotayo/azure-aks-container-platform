const express = require('express');
const crypto = require('crypto');
const { createJob, getJob } = require('../lib/tableClient');
const { enqueueJob } = require('../lib/queueClient');

const router = express.Router();

router.post('/', async (req, res) => {
  const jobId = crypto.randomUUID();

  try {
    await createJob(jobId);
    await enqueueJob(jobId);

    res.status(202).json({ jobId, status: 'queued' });
  } catch (err) {
    console.error('Failed to create job:', err);
    res.status(500).json({ error: 'failed to create job' });
  }
});

router.get('/:id', async (req, res) => {
  try {
    const job = await getJob(req.params.id);

    if (!job) {
      return res.status(404).json({ error: 'job not found' });
    }

    res.status(200).json({
      jobId: job.rowKey,
      status: job.status,
      result: job.result,
      createdAt: job.createdAt,
    });
  } catch (err) {
    console.error('Failed to fetch job:', err);
    res.status(500).json({ error: 'failed to fetch job' });
  }
});

module.exports = router;

