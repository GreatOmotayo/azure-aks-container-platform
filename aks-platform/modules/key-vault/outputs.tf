output "vault_id" {
  description = "Consumed by modules/key-vault-private endpoint's private_service_connection"
  value       = azurerm_key_vault.this.id
}

output "vault_uri" {
  description = "The vault's FQDN"
  value       = azurerm_key_vault.this.vault_uri
}

output "vault_name" {
  value = azurerm_key_vault.this.name
}

output "tenant_id" {
  description = "Required by every SecretProviderClass's tenantId parameter"
  value       = data.azurerm_client_config.current.tenant_id
}