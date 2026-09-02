output "cluster_id" {
  value = azurerm_kubernetes_cluster.this.id
}

output "cluster_name" {
  value = azurerm_kubernetes_cluster.this.name
}

output "private_fqdn" {
  description = "Private FQDN of the API server - resolvable only from VNets linked to the custom private DNS zone (hub + workload)"
  value       = azurerm_kubernetes_cluster.this.private_fqdn
}

output "node_resource_group" {
  description = "AKS-managed MC_* resource group - the VMSS instances, internal load balancer, and managed disks live here, nor in resource_group_name"
  value       = azurerm_kubernetes_cluster.this.node_resource_group
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL - required when federating a workload identity credential to an individual pod's kubernetes service account in a later phase"
  value       = azurerm_kubernetes_cluster.this.oidc_issuer_url
}

output "kubelet_identity_object_id" {
  description = "Object ID of the kubelet identity - this is the identity AKS itself uses to pull images, so it's what needs AcrPull granted on the container registry, wired up when Helm charts are built in a later phase"
  value       = azurerm_kubernetes_cluster.this.kubelet_identity[0].object_id
}

output "cluster_identity_principal_id" {
  description = "Principal ID of the user assigned control plane identity from this file's - exposed in case a later phase needs to grant it an additional role (e.g if key vault access needs adjusting)"
  value       = azurerm_user_assigned_identity.aks.principal_id
}
