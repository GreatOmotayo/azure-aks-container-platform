output "client_id" {
  description = "Referenced by gitops/apps/velero.yaml's serviceaccount.server.annotations - this is what ties Velero's ServiceAccount to this specific Azure Identity"
  value       = azurerm_user_assigned_identity.velero.client_id
}