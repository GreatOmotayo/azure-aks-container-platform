output "aduke_client_id" {
  description = "The client ID Aduke's service Account annotation reference in the Helm chart"
  value       = azurerm_user_assigned_identity.aduke.client_id
}

output "worker_client_id" {
  description = "Same purpose as aduke_client_id, for the worker Service Account"
  value       = azurerm_user_assigned_identity.worker.client_id
}