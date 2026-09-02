data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "this" {
  name                          = var.vault_name
  location                      = var.location
  resource_group_name           = var.resource_group_name
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  public_network_access_enabled = true
  purge_protection_enabled      = true
  soft_delete_retention_days    = 7

  tags = var.tags
}

# --- Human admin access ---
resource "azurerm_role_assignment" "admin_group_kv_admin" {
  for_each = toset(var.admin_group_object_ids)

  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = each.value
}

# --- Terraform's own write access ---
resource "azurerm_role_assignment" "terraform_kv_secrets_officer" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}
