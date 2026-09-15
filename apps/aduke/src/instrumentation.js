const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { resourceFromAttributes } = require('@opentelemetry/resources');
const { ATTR_SERVICE_NAME, ATTR_SERVICE_VERSION } = require('@opentelemetry/semantic-conventions');
const { AzureMonitorTraceExporter, AzureMonitorMetricExporter } = require('@azure/monitor-opentelemetry-exporter');
const { WorkloadIdentityCredential } = require('@azure/identity');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');

const credential = new WorkloadIdentityCredential({
  tenantId: process.env.AZURE_TENANT_ID,
  clientId: process.env.AZURE_CLIENT_ID,
  tokenFilePath: process.env.AZURE_FEDERATED_TOKEN_FILE,
});

// connectionString identifies WHICH App Insights resource to send to;
// credential controls HOW the exporter authenticates to it (Entra ID
// token auth instead of the connection string's embedded instrumentation
// key alone).
const connectionString = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;

const traceExporter = new AzureMonitorTraceExporter({
  connectionString,
  credential,
});

const metricExporter = new AzureMonitorMetricExporter({
  connectionString,
  credential,
});

const sdk = new NodeSDK({
  resource: resourceFromAttributes({
    [ATTR_SERVICE_NAME]: 'aduke',
    [ATTR_SERVICE_VERSION]: process.env.APP_VERSION || 'unknown',
    'deployment.environment': process.env.NODE_ENV || 'production',
  }),
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 15000,
  }),
  instrumentations: [
    getNodeAutoInstrumentations({
      '@opentelemetry/instrumentation-fs': { enabled: false },
    }),
  ],
});

sdk.start();

process.on('SIGTERM', () => {
  sdk.shutdown().finally(() => process.exit(0));
});