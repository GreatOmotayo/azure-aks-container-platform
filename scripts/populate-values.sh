#!/usr/bin/env bash
# Replaces the manual "copy each terraform output into values.yaml by
# hand" step (docs/VALIDATION-PLAN.md Section 2.1) with an automated one.
# Uses yq (YAML-aware editing), not sed - sed does blind text
# substitution and risks corrupting YAML structure if a value ever
# contains a character sed treats specially; yq understands the file as
# actual YAML and edits specific keys safely regardless of content.
#
# Run this from the repo root, AFTER `terraform apply` has succeeded.
# Requires: yq (https://github.com/mikefarah/yq), jq, terraform.
set -euo pipefail

if ! command -v yq &> /dev/null; then
  echo "yq is required but not installed. See https://github.com/mikefarah/yq"
  exit 1
fi

cd aks-platform
OUTPUTS=$(terraform output -json)
cd ..

get() { echo "$OUTPUTS" | jq -r ".$1.value"; }

REGISTRY_LOGIN_SERVER=$(get registry_login_server)
ADUKE_CLIENT_ID=$(get aduke_workload_identity_client_id)
WORKER_CLIENT_ID=$(get worker_workload_identity_client_id)
VELERO_CLIENT_ID=$(get velero_identity_client_id)
KEY_VAULT_NAME=$(get key_vault_name)
KEY_VAULT_URI=$(get key_vault_uri)
TENANT_ID=$(get key_vault_tenant_id)
STORAGE_ACCOUNT_NAME=$(get storage_account_name)
VELERO_CONTAINER_NAME=$(get velero_backup_container_name)

echo "=== Populating charts/aduke/values.yaml ==="
yq -i "
  .image.repository |= sub(\"^[^/]+\"; \"${REGISTRY_LOGIN_SERVER}\") |
  .serviceAccount.azureClientId = \"${ADUKE_CLIENT_ID}\" |
  .keyVault.name = \"${KEY_VAULT_NAME}\" |
  .keyVault.vaultUri = \"${KEY_VAULT_URI}\" |
  .azureTenantId = \"${TENANT_ID}\"
" charts/aduke/values.yaml

echo "=== Populating charts/worker/values.yaml ==="
yq -i "
  .image.repository |= sub(\"^[^/]+\"; \"${REGISTRY_LOGIN_SERVER}\") |
  .serviceAccount.azureClientId = \"${WORKER_CLIENT_ID}\" |
  .keyVault.name = \"${KEY_VAULT_NAME}\" |
  .keyVault.vaultUri = \"${KEY_VAULT_URI}\" |
  .azureTenantId = \"${TENANT_ID}\"
" charts/worker/values.yaml

echo "=== Populating gitops/apps/velero.yaml ==="
# velero.yaml's real values live inside a multi-line embedded Helm
# `values:` block (a YAML string, not nested structure) - yq can't
# target individual keys inside that string the way it can for a real
# values.yaml file. Simple, targeted sed substitutions are safe here
# specifically because we're replacing exact, unique placeholder tokens
# within a known string block, not doing broad text surgery on real YAML
# structure.
#
# Match by KEY NAME (azure.workload.identity/client-id, bucket,
# storageAccount), not by a trailing comment. An earlier version of this
# script matched against a comment that turned out not to exist in the
# real file at all - the actual file has three bare, identical
# "REPLACE_WITH_TERRAFORM_OUTPUT" placeholders with no distinguishing
# comment. Matching by key name is also more robust regardless: key
# names are functionally required for the Helm chart to work, so they're
# far less likely to drift or be edited away than a comment would be.
#
# Deliberately NOT using `sed -i` at all - macOS (BSD sed) and Linux
# (GNU sed) handle that flag's optional backup-suffix argument
# differently, and platform detection still produced confusing extra
# stderr noise on GNU sed even when "working". Redirecting to a temp
# file and moving it back sidesteps the inconsistency entirely.
TMP_VELERO=$(mktemp)
sed \
  -e "s|azure.workload.identity/client-id: \"REPLACE_WITH_TERRAFORM_OUTPUT\"|azure.workload.identity/client-id: \"${VELERO_CLIENT_ID}\"|" \
  -e "s|bucket: \"REPLACE_WITH_TERRAFORM_OUTPUT\"|bucket: \"${VELERO_CONTAINER_NAME}\"|" \
  -e "s|storageAccount: \"REPLACE_WITH_TERRAFORM_OUTPUT\"|storageAccount: \"${STORAGE_ACCOUNT_NAME}\"|" \
  gitops/apps/velero.yaml > "$TMP_VELERO"
mv "$TMP_VELERO" gitops/apps/velero.yaml

echo ""
echo "=== Done. Confirm no REPLACE_WITH_TERRAFORM_OUTPUT placeholders remain: ==="
grep -rn "REPLACE_WITH_TERRAFORM_OUTPUT" charts/ gitops/ && echo "WARNING: placeholders still remain above" || echo "Clean - no placeholders left"

echo ""
echo "Review the diff, then commit and push:"
echo "  git diff charts/ gitops/"
echo "  git add charts/ gitops/"
echo "  git commit -m 'chore: populate values.yaml from terraform output'"
echo "  git push origin main"