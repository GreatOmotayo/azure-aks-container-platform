output "cluster_name" {
  value = module.aks.cluster_name
}

output "cluster_private_fqdn" {
  description = "The private FQDN to nslookup from the Bastion jumpbox when validating DNS resolution post-deploy"
  value       = module.aks.private_fqdn
}

output "node_resource_group" {
  description = "AKS-managed MC_* resource group holding the actual VMSS, load balancer, and disks"
  value       = module.aks.node_resource_group
}

output "oidc_issuer_url" {
  description = "Needed in a later phase when federating Workload Identity credentials for Aduke's and the worker's ServiceAccounts"
  value       = module.aks.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Needed in a later phase to grant AcrPull on the container registry"
  value       = module.aks.kubelet_identity_object_id
}

output "private_dns_zone_name" {
  description = "The custom zone name - useful for confirming which zone a private_fqdn resolves through"
  value       = module.aks_private_dns.zone_name
}

output "aduke_workload_identity_client_id" {
  description = "Referenced by charts/aduke/templates/serviceaccount.yaml's azure.workload.identity/client-id annotation"
  value       = module.workload_identity.aduke_client_id
}

output "worker_workload_identity_client_id" {
  description = "Referenced by charts/worker/templates/serviceaccount.yaml's azure.workload.identity/client-id annotation"
  value       = module.workload_identity.worker_client_id
}

output "storage_account_name" {
  description = "Not a secret - the real value to source into both apps' STORAGE_ACCOUNT_NAME config via the Key Vault CSI driver"
  value       = module.storage.storage_account_name
}

output "key_vault_name" {
  description = "The plain vault name (not its URI) - required by charts/*/values.yaml's keyVault.name, which the SecretProviderClass's keyvaultName parameter needs"
  value       = module.key_vault.vault_name
}

output "key_vault_uri" {
  description = "Required by charts/*/values.yaml's keyVault.vaultUri"
  value       = module.key_vault.vault_uri
}

output "key_vault_tenant_id" {
  description = "Required by charts/*/values.yaml's azureTenantId, which every SecretProviderClass's tenantId parameter needs"
  value       = module.key_vault.tenant_id
}

output "velero_identity_client_id" {
  description = "Referenced by gitops/apps/velero.yaml's serviceAccount.server.annotations - ties Velero's ServiceAccount to its own dedicated identity"
  value       = module.velero_identity.client_id
}

# output "velero_backup_container_name" {
#   description = "Passed through to gitops/apps/velero.yaml's backupStorageLocation config"
#   value       = module.storage.velero_backup_container_name
# }

output "registry_login_server" {
  description = "A real gap this automation surfaced - genuinely missing until now. Needed by charts/aduke/values.yaml and charts/worker/values.yaml's image.repository field (login_server + app name)."
  value       = module.container_registry.login_server
}
