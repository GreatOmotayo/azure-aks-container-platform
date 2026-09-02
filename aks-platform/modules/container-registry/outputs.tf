output "login_server" {
  description = "The registry's login server FQDN"
  value       = azurerm_container_registry.this.login_server
}

output "registry_id" {
  value = azurerm_container_registry.this.id
}

output "registry_name" {
  value = azurerm_container_registry.this.name
}