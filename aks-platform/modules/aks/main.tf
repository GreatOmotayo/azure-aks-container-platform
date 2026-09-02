resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-aks-${var.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_role_assignment" "aks_network" {
  scope                = var.subnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "azurerm_role_assignment" "aks_private_dns" {
  scope                = var.private_dns_zone_id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.aks.principal_id
}

resource "time_sleep" "wait_for_role_propagation" {
  depends_on      = [azurerm_role_assignment.aks_network, azurerm_role_assignment.aks_private_dns]
  create_duration = "60s"
}

resource "azurerm_kubernetes_cluster" "this" {
  name                    = "aks-${var.environment}"
  location                = var.location
  resource_group_name     = var.resource_group_name
  dns_prefix              = "aks-${var.environment}"
  kubernetes_version      = var.kubernetes_version
  private_cluster_enabled = true
  private_dns_zone_id     = var.private_dns_zone_id

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks.id]
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    pod_cidr            = var.pod_cidr
    service_cidr        = var.service_cidr
    dns_service_ip      = var.dns_service_ip
    outbound_type       = "userDefinedRouting"
  }

  default_node_pool {
    name                         = "system"
    vm_size                      = var.system_node_vm_size
    node_count                   = var.system_node_count
    vnet_subnet_id               = var.subnet_id
    only_critical_addons_enabled = true
    os_disk_type                 = "Managed"
    tags                         = var.tags
    upgrade_settings {
      max_surge = "33%"
    }
  }

  auto_scaler_profile {
    scale_down_delay_after_add = "5m"
    scale_down_unneeded        = "5m"
    expander                   = "least-waste"
  }

  oidc_issuer_enabled       = true
  workload_identity_enabled = true

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled     = true
    admin_group_object_ids = var.admin_group_object_ids
  }
  local_account_disabled = true

  key_vault_secrets_provider {
    secret_rotation_enabled  = true
    secret_rotation_interval = "2m"
  }

  oms_agent {
    log_analytics_workspace_id = var.log_analytics_workspace_id
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [kubernetes_version]
  }

  depends_on = [time_sleep.wait_for_role_propagation]
}

resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "user"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.this.id
  vm_size               = var.user_node_vm_size
  vnet_subnet_id        = var.subnet_id
  mode                  = "User"
  os_disk_type          = "Managed"

  auto_scaling_enabled = true
  min_count            = var.user_node_min_count
  max_count            = var.user_node_max_count

  upgrade_settings {
    max_surge = "33%"
  }

  tags = var.tags
}