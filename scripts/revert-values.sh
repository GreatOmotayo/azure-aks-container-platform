#!/usr/bin/env bash
# The mirror image of populate-values.sh - resets every real value back to
# the REPLACE_WITH_TERRAFORM_OUTPUT placeholder, regardless of what the
# current value actually is. Useful for resetting to a clean template
# state, or re-testing populate-values.sh from scratch without needing to
# manually retype every placeholder by hand.
#
# Run from the repo root.
set -euo pipefail

if ! command -v yq &> /dev/null; then
  echo "yq is required but not installed. See https://github.com/mikefarah/yq"
  exit 1
fi

PLACEHOLDER="REPLACE_WITH_TERRAFORM_OUTPUT"

echo "=== Reverting charts/aduke/values.yaml ==="
yq -i "
  .image.repository |= sub(\"^[^/]+\"; \"REPLACE_WITH_ACR_LOGIN_SERVER\") |
  .serviceAccount.azureClientId = \"${PLACEHOLDER}\" |
  .keyVault.name = \"${PLACEHOLDER}\" |
  .keyVault.vaultUri = \"${PLACEHOLDER}\" |
  .azureTenantId = \"${PLACEHOLDER}\"
" charts/aduke/values.yaml

echo "=== Reverting charts/worker/values.yaml ==="
yq -i "
  .image.repository |= sub(\"^[^/]+\"; \"REPLACE_WITH_ACR_LOGIN_SERVER\") |
  .serviceAccount.azureClientId = \"${PLACEHOLDER}\" |
  .keyVault.name = \"${PLACEHOLDER}\" |
  .keyVault.vaultUri = \"${PLACEHOLDER}\" |
  .azureTenantId = \"${PLACEHOLDER}\"
" charts/worker/values.yaml

echo "=== Reverting gitops/apps/velero.yaml ==="
# Same reasoning as populate-values.sh: velero.yaml's real values live
# inside an embedded Helm values string, not real YAML structure, so yq
# can't target them - sed by KEY NAME instead. Matches "[^\"]*" (ANY
# current quoted value) rather than a specific known value, so this
# works regardless of what's currently populated there - no need to
# already know what value to revert FROM.
#
# Same portability reasoning as populate-values.sh: redirect to a temp
# file and move it back, rather than `sed -i`, which macOS (BSD sed) and
# Linux (GNU sed) handle inconsistently.
TMP_VELERO=$(mktemp)
sed \
  -e 's|azure.workload.identity/client-id: "[^"]*"|azure.workload.identity/client-id: "'"${PLACEHOLDER}"'"|' \
  -e 's|bucket: "[^"]*"|bucket: "'"${PLACEHOLDER}"'"|' \
  -e 's|storageAccount: "[^"]*"|storageAccount: "'"${PLACEHOLDER}"'"|' \
  gitops/apps/velero.yaml > "$TMP_VELERO"
mv "$TMP_VELERO" gitops/apps/velero.yaml

echo ""
echo "=== Done. Confirming all three files now contain placeholders: ==="
grep -c "$PLACEHOLDER" charts/aduke/values.yaml charts/worker/values.yaml gitops/apps/velero.yaml

echo ""
echo "Review the diff before committing - this is a real, tracked change:"
echo "  git diff charts/ gitops/"