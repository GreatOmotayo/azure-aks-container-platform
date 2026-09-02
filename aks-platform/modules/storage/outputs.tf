output "storage_account_id" {
  description = "Consumed by modules/storage private endpoints private service connection"
  value       = azurerm_storage_account.this.id
}

output "storage_account_name" {
  description = "This is real that replaces STORAGE_ACCOUNT_NAME in the app's key vault"
  value       = azurerm_storage_account.this.name
}

output "queue_name" {
  value = azurerm_storage_queue.jobs.name
}

output "velero_backup_container_name" {
  description = "Consumed by the Velero Helm values to configure its backup storage location"
  value       = azurerm_storage_container.velero_backups.name
}