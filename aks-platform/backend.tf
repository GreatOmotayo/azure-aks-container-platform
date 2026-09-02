terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "omotayotfstate"
    container_name       = "tf-state"
    key                  = "aks-container-platform.tfstate"
    use_oidc             = true
    use_azuread_auth     = true
  }
}
