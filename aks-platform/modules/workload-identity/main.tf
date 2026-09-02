resource "azurerm_user_assigned_identity" "aduke" {
  name                = "id-aduke-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_user_assigned_identity" "worker" {
  name                = "id-worker-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "aduke" {
  name                      = "fic-aduke-${var.environment}"
  user_assigned_identity_id = azurerm_user_assigned_identity.aduke.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.aks_oidc_issuer_url
  subject                   = "system:serviceaccount:${var.app_namespace}:aduke"
}

resource "azurerm_federated_identity_credential" "worker" {
  name                      = "fic-worker-${var.environment}"
  user_assigned_identity_id = azurerm_user_assigned_identity.worker.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.aks_oidc_issuer_url
  subject                   = "system:serviceaccount:${var.app_namespace}:worker"
}

resource "azurerm_role_assignment" "aduke_kv" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.aduke.principal_id
}

resource "azurerm_role_assignment" "worker_kv" {
  scope                = var.key_vault_id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.worker.principal_id
}

resource "azurerm_role_assignment" "aduke_queue_send" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Queue Data Message Sender"
  principal_id         = azurerm_user_assigned_identity.aduke.principal_id
}

resource "azurerm_role_assignment" "worker_queue_process" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Queue Data Message Processor"
  principal_id         = azurerm_user_assigned_identity.worker.principal_id
}

resource "azurerm_role_assignment" "aduke_table" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.aduke.principal_id
}

resource "azurerm_role_assignment" "worker_table" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_user_assigned_identity.worker.principal_id
}

