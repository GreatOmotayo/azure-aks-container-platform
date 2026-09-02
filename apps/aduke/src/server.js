const express = require('express');
const path = require('path');
const jobsRouter = require('./routes/jobs');
const { isTableStorageReachable } = require('./lib/tableClient');

const app = express();
const PORT = process.env.PORT || 3000;

app.use(express.json());

app.use(express.static(path.join(__dirname, '..', 'public')));

// --- Liveness: is the process itself alive? ---
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

// --- Readiness: can this pod actually serve traffic right now? ---
app.get('/ready', async (req, res) => {
  const reachable = await isTableStorageReachable();
  if (reachable) {
    res.status(200).json({ status: 'ready' });
  } else {
    res.status(503).json({ status: 'not ready', reason: 'table storage unreachable' });
  }
});

app.use('/jobs', jobsRouter);

// Catch-all error handler - never leak internals in the response body
app.use((err, req, res, next) => {
  console.error(err);
  res.status(500).json({ error: 'internal server error' });
});

app.listen(PORT, () => {
  console.log(`Aduke listening on port ${PORT}`);
});
