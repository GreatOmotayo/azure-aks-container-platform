data "azurerm_client_config" "current" {}

# --- Own Log Analytics workspace ---
resource "azurerm_log_analytics_workspace" "this" {
  name                = "log-${var.environment}"
  location             = var.location
  resource_group_name = azurerm_resource_group.app.name
  sku                   = "PerGB2018"
  retention_in_days    = 30
  tags                  = var.project_tags
}

# --- App resource group ---
resource "azurerm_resource_group" "app" {
  name     = "rg-aks-app"
  location = var.location
  tags     = var.project_tags
}

# --- Standalone network ---
module "network" {
  source = "./modules/network"

  environment                   = var.environment
  location                       = var.location
  resource_group_name           = azurerm_resource_group.app.name
  vnet_cidr                      = var.vnet_cidr
  aks_subnet_cidr                = var.aks_subnet_cidr
  jumpbox_subnet_cidr            = var.jumpbox_subnet_cidr
  jumpbox_allowed_ssh_source_ip = var.jumpbox_allowed_ssh_source_ip
  tags                            = var.project_tags
}

module "aks_private_dns" {
  source = "./modules/aks-private-dns"

  location             = var.location
  resource_group_name = azurerm_resource_group.app.name
  environment           = var.environment
  vnet_id               = module.network.vnet_id
  tags                  = var.project_tags
}

# --- Pre-created Container Insights Solution ---
module "container_insights_solution" {
  source = "./modules/container-insights-solution"

  location                       = var.location
  workspace_resource_group_name = azurerm_resource_group.app.name
  log_analytics_workspace_id    = azurerm_log_analytics_workspace.this.id
  log_analytics_workspace_name  = azurerm_log_analytics_workspace.this.name
  tags                           = var.project_tags
}

module "aks" {
  source = "./modules/aks"

  environment          = var.environment
  location             = var.location
  resource_group_name = azurerm_resource_group.app.name
  kubernetes_version   = var.kubernetes_version

  subnet_id            = module.network.aks_subnet_id
  private_dns_zone_id = module.aks_private_dns.zone_id

  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  admin_group_object_ids      = var.aks_admin_group_object_ids

  system_node_vm_size = var.system_node_vm_size
  system_node_count   = var.system_node_count
  user_node_vm_size   = var.user_node_vm_size
  user_node_min_count = var.user_node_min_count
  user_node_max_count = var.user_node_max_count

  tags = var.project_tags

  depends_on = [module.container_insights_solution]
}

# --- Cluster RBAC ---
resource "azurerm_role_assignment" "aks_rbac_admin" {
  for_each = toset(var.aks_admin_group_object_ids)

  scope                = module.aks.cluster_id
  role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id          = each.value
}

# --- Jumpbox ---
module "jumpbox" {
  source = "./modules/jumpbox"

  environment            = var.environment
  location               = var.location
  resource_group_name   = azurerm_resource_group.app.name
  subnet_id              = module.network.jumpbox_subnet_id
  ssh_public_key         = var.ssh_public_key
  admin_group_object_ids = var.aks_admin_group_object_ids
  tags                    = var.project_tags
}

# --- Container Registry ---
module "container_registry" {
  source = "./modules/container-registry"

  registry_name              = var.registry_name
  location                    = var.location
  resource_group_name        = azurerm_resource_group.app.name
  kubelet_identity_object_id = module.aks.kubelet_identity_object_id
  tags                        = var.project_tags
}

# --- CI's own push access ---
resource "azurerm_role_assignment" "ci_acr_push" {
  scope                = module.container_registry.registry_id
  role_definition_name = "AcrPush"
  principal_id          = data.azurerm_client_config.current.object_id
}

# --- Key Vault ---
module "key_vault" {
  source = "./modules/key-vault"

  vault_name           = var.vault_name
  location             = var.location
  resource_group_name = azurerm_resource_group.app.name
  admin_group_object_ids = var.aks_admin_group_object_ids
  tags                  = var.project_tags
}

# --- Storage Account (Queue + Table) ---
module "storage" {
  source = "./modules/storage"

  storage_account_name = var.storage_account_name
  location             = var.location
  resource_group_name = azurerm_resource_group.app.name
  tags                  = var.project_tags
}

# --- Workload Identity federation ---
module "workload_identity" {
  source = "./modules/workload-identity"

  environment          = var.environment
  location             = var.location
  resource_group_name = azurerm_resource_group.app.name
  aks_oidc_issuer_url = module.aks.oidc_issuer_url
  key_vault_id         = module.key_vault.vault_id
  storage_account_id   = module.storage.storage_account_id
  tags                  = var.project_tags
}

# --- Key Vault secret: storage-account-name ---
resource "time_sleep" "wait_for_kv_propagation" {
  depends_on      = [module.key_vault, module.storage]
  create_duration = "180s"
}

resource "azurerm_key_vault_secret" "storage_account_name" {
  name         = "storage-account-name"
  value        = module.storage.storage_account_name
  key_vault_id = module.key_vault.vault_id

  depends_on = [time_sleep.wait_for_kv_propagation]
}

# --- Velero's dedicated Workload Identity ---
module "velero_identity" {
  source = "./modules/velero-identity"

  environment          = var.environment
  location             = var.location
  resource_group_name = azurerm_resource_group.app.name
  aks_oidc_issuer_url = module.aks.oidc_issuer_url
  storage_account_id   = module.storage.storage_account_id
  velero_backup_container_name = module.storage.velero_backup_container_name
  tags                  = var.project_tags
}
