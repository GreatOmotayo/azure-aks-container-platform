resource "azurerm_container_registry" "this" {
  name                = var.registry_name
  resource_group_name = var.resource_group_name
  location            = var.location
  sku                 = "Standard"
  admin_enabled       = false
  public_network_access_enabled = true

  tags = var.tags
}

# --- AcrPull for the cluster's kubelet identity ---
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id          = var.kubelet_identity_object_id
}
