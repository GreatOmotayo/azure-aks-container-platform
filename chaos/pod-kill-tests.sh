#!/usr/bin/env bash
# Resilience test: deliberately kill a worker pod, ideally mid-job, and
# confirm two SEPARATE recovery mechanisms both actually work:
#   1. Kubernetes reschedules a replacement pod (the Deployment's job)
#   2. The in-flight job's queue message becomes available again for
#      another replica to pick up (the queue's visibility-timeout
#      mechanism - apps/worker/src/lib/queueClient.js - NOT something
#      Kubernetes provides on its own)
#
# Run this from the Bastion jumpbox, where kubectl is already configured.
set -euo pipefail

NAMESPACE="app"

echo "=== Step 1: Current worker pods (baseline) ==="
kubectl get pods -n "$NAMESPACE" -l app=worker -o wide

echo ""
echo "=== Step 2: Enqueue a job so there's something in-flight to interrupt ==="
echo "Run this from another terminal/session, timed to land while the pod below is being killed:"
echo "  curl -X POST http://<aduke-ingress-host>/jobs"
echo ""
read -p "Press Enter once a job has been submitted and is likely processing... " -r

echo ""
echo "=== Step 3: Pick a worker pod and kill it ==="
TARGET_POD=$(kubectl get pods -n "$NAMESPACE" -l app=worker -o jsonpath='{.items[0].metadata.name}')
echo "Killing pod: $TARGET_POD"
kubectl delete pod "$TARGET_POD" -n "$NAMESPACE" --grace-period=0 --force

echo ""
echo "=== Step 4: Watch Kubernetes reschedule a replacement (mechanism 1) ==="
echo "Watching for 30s - confirm a NEW pod (different name) reaches Running:"
timeout 30 kubectl get pods -n "$NAMESPACE" -l app=worker -w || true

echo ""
echo "=== Step 5: Confirm the PDB was respected during this ==="
kubectl get pdb worker -n "$NAMESPACE"
echo "PASS criteria: ALLOWED DISRUPTIONS should never have dropped to 0 during the kill - if it did, the PDB failed to protect against this specific disruption."

echo ""
echo "=== Step 6: Confirm the job itself eventually completed (mechanism 2) ==="
echo "This is the part Kubernetes does NOT handle on its own - the queue's"
echo "60s visibility timeout (apps/worker/src/lib/queueClient.js) is what"
echo "makes the interrupted job's message reappear for a DIFFERENT worker"
echo "replica to pick up, rather than the job being silently lost."
echo ""
echo "Check the job's status via Aduke's API (replace <job-id> with the ID"
echo "returned when you submitted the job in Step 2):"
echo "  curl http://<aduke-ingress-host>/jobs/<job-id>"
echo ""
echo "PASS criteria: status eventually reaches 'done', even though the pod"
echo "that originally picked it up no longer exists. If status stays"
echo "'queued' forever, the queue's retry mechanism didn't work as designed."