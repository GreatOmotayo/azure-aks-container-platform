resource "azurerm_storage_account" "this" {
  name                = var.storage_account_name
  resource_group_name = var.resource_group_name
  location            = var.location

  account_tier             = "Standard"
  account_replication_type = "LRS"
  account_kind             = "StorageV2"

  min_tls_version               = "TLS1_2"
  public_network_access_enabled = true
  shared_access_key_enabled     = false

  tags = var.tags
}

# --- Terraform-executing identity's own data-plane RBAC ---
data "azurerm_client_config" "current" {}

resource "azurerm_role_assignment" "terraform_queue_data" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "terraform_table_data" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "terraform_blob_data" {
  scope                = azurerm_storage_account.this.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "time_sleep" "wait_for_storage_rbac_propagation" {
  depends_on      = [azurerm_role_assignment.terraform_queue_data, azurerm_role_assignment.terraform_table_data, azurerm_role_assignment.terraform_blob_data]
  create_duration = "60s"
}

# --- Data-plane sub-resources: queue, table, container ---
resource "azurerm_storage_queue" "jobs" {
  name               = "jobs"
  storage_account_id = azurerm_storage_account.this.id

  depends_on = [time_sleep.wait_for_storage_rbac_propagation]
}

# --- Phase 5: Velero backup container ---
resource "azurerm_storage_container" "velero_backups" {
  name                  = "velero-backups"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"

  depends_on = [time_sleep.wait_for_storage_rbac_propagation]
}