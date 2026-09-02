resource "azurerm_user_assigned_identity" "velero" {
  name                = "id-velero-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "velero" {
  name                      = "fic-velero-${var.environment}"
  user_assigned_identity_id = azurerm_user_assigned_identity.velero.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = var.aks_oidc_issuer_url
  subject                   = "system:serviceaccount:velero:velero"
}

resource "azurerm_role_assignment" "velero_blob" {
  scope                = var.storage_account_id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.velero.principal_id
}