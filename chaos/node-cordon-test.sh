#!/usr/bin/env bash
# Resilience test: simulate the realistic scenario a PDB actually exists
# for - a node being taken out of service for maintenance or a cluster
# upgrade (NOT a crash) - and confirm every pod on it gets rescheduled
# elsewhere WITHOUT the PDB's minAvailable guarantee ever being violated.
#
# This is a different failure mode than pod-kill-test.sh: that one tests
# an abrupt, ungraceful death. This one tests a GRACEFUL, voluntary
# eviction - the exact scenario cordon/drain and PDBs are designed around.
#
# Run this from the jumpbox, where kubectl is already configured
# against the private cluster.
set -euo pipefail

NAMESPACE="app"

echo "=== Step 1: Current node and pod distribution (baseline) ==="
kubectl get nodes -o wide
echo ""
kubectl get pods -n "$NAMESPACE" -o wide

echo ""
echo "=== Step 2: Pick a node that's actually running workload pods ==="
read -p "Enter the node name to cordon and drain: " TARGET_NODE

echo ""
echo "=== Step 3: Cordon the node (mark unschedulable, don't evict yet) ==="
kubectl cordon "$TARGET_NODE"
kubectl get nodes "$TARGET_NODE"
echo "Confirm SCHEDULING DISABLED shows above before proceeding."

echo ""
echo "=== Step 4: Check the PDB's current allowed-disruption budget BEFORE draining ==="
kubectl get pdb -n "$NAMESPACE"

echo ""
read -p "Press Enter to begin the drain... " -r

echo ""
echo "=== Step 5: Drain the node - this is where PDBs actually get enforced ==="
echo "kubectl drain respects PDBs automatically - if evicting a pod would"
echo "violate minAvailable, the drain BLOCKS on that pod rather than"
echo "violating the budget. Watch for this behavior, don't just wait for"
echo "it to finish silently."
kubectl drain "$TARGET_NODE" \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=300s

echo ""
echo "=== Step 6: Confirm pods rescheduled onto OTHER nodes ==="
kubectl get pods -n "$NAMESPACE" -o wide
echo "PASS criteria: every pod that was on $TARGET_NODE now shows a DIFFERENT node in the NODE column, and all pods reach Running."

echo ""
echo "=== Step 7: Confirm the PDB was never actually violated during the drain ==="
kubectl get pdb -n "$NAMESPACE"
echo "PASS criteria: ALLOWED DISRUPTIONS returned to its normal value - if this ever showed a state where fewer pods were available than minAvailable permits, the PDB failed to do its job."

echo ""
echo "=== Step 8: Uncordon - restore the node to schedulable state ==="
read -p "Press Enter to uncordon $TARGET_NODE and restore it to service... " -r
kubectl uncordon "$TARGET_NODE"
kubectl get nodes "$TARGET_NODE"
echo "Confirm SCHEDULING DISABLED is gone."