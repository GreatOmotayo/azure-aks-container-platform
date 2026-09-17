// instrumentation.js — must be required before any other app code
const connectionString = process.env.APPLICATIONINSIGHTS_CONNECTION_STRING;

if (!connectionString) {
  // Matches the appInsights.enabled: false default in the Helm chart —
  // Aduke must be able to run with telemetry disabled without crashing.
  // Without this guard, the exporters below throw on an undefined
  // connection string, taking down the whole process at startup.
  console.warn(
    '[instrumentation] APPLICATIONINSIGHTS_CONNECTION_STRING not set — ' +
    'skipping OpenTelemetry setup. Set appInsights.enabled=true in the ' +
    'Helm chart once azure-aks-observability-platform has provisioned it.'
  );
} else {
  const { NodeSDK } = require('@opentelemetry/sdk-node');
  const { HttpInstrumentation } = require('@opentelemetry/instrumentation-http');
  const { ExpressInstrumentation } = require('@opentelemetry/instrumentation-express');
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

  const traceExporter = new AzureMonitorTraceExporter({ connectionString, credential });
  const metricExporter = new AzureMonitorMetricExporter({ connectionString, credential });

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
      new HttpInstrumentation(),
      new ExpressInstrumentation(),
    ],
  });
  sdk.start();

  console.log('[instrumentation] OpenTelemetry started');
}