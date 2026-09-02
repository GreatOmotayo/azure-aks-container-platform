# --- Subscription ---
variable "subscription_id" {
  description = "The single Azure subscription everything in this project lives in"
  type        = string
}

variable "client_id" {
  description = "The CI Service Principal's Application (client) ID - same value as the AZURE_CLIENT_ID GitHub secret"
  type        = string
}

variable "tenant_id" {
  description = "The Microsoft Entra tenant ID - same value as the AZURE_TENANT_ID GitHub secret"
  type        = string
}

# --- General ---

variable "environment" {
  description = "Environment name, threaded through to every module for resource naming. This project deploys Production only - naming stays environment-aware so a future promotion is a resource-group/VNet swap, not a rewrite."
  type        = string
  default     = "production"
}

variable "location" {
  type    = string
  default = "centralus"
}

variable "project_tags" {
  description = "Common tags applied to every resource in this project"
  type        = map(string)
  default = {
    project     = "aks-container-platform"
    managed_by  = "terraform"
    environment = "production"
    CostCenter  = "platform-engineering"
  }
}

# --- Standalone network ---
# Replaces the earlier hub-and-spoke integration entirely - see
# DECISIONS.md for the full cost-driven reasoning.

variable "vnet_cidr" {
  description = "Address space for this project's own standalone VNet"
  type        = string
  default     = "10.10.0.0/16"
}

variable "aks_subnet_cidr" {
  type    = string
  default = "10.10.0.0/22"
}

variable "jumpbox_subnet_cidr" {
  type    = string
  default = "10.10.4.0/24"
}

variable "jumpbox_allowed_ssh_source_ip" {
  description = "The one real access control replacing Bastion (now removed) - SSH to the jumpbox is only ever reachable from this specific IP/CIDR. Update this if your own IP changes."
  type        = string
}

variable "ssh_public_key" {
  description = "Public SSH key for the jumpbox's break-glass fallback login. Day-to-day access is the AAD login extension, gated by admin_group_object_ids below - this key is a secondary, not the primary access path."
  type        = string
}

# --- AKS cluster ---

variable "kubernetes_version" {
  description = "Kubernetes minor version for the cluster. Left unpinned (null) by default so patch versions roll automatically; set explicitly once the cluster is stable to control upgrade timing deliberately."
  type        = string
  default     = null
}

variable "system_node_vm_size" {
  description = "VM size for the system node pool - Standard_D2s_v6"
  type        = string
  default     = "Standard_D2s_v6"
}

variable "system_node_count" {
  type    = number
  default = 2
}

variable "user_node_vm_size" {
  type    = string
  default = "Standard_D2s_v6"
}

variable "user_node_min_count" {
  type    = number
  default = 2
}

variable "user_node_max_count" {
  description = "Maximum nodes in the user pool autoscaler - the ceiling the k6 load test can grow into. Constrained by this subscription's real EBDSv5 quota (10 vCPU total): system pool (2 x 2 vCPU = 4) + user pool at max (3 x 2 vCPU = 6) = 10 vCPU exactly."
  type        = number
  default     = 3
}

variable "aks_admin_group_object_ids" {
  description = "Entra ID group object ID(s) granted Azure RBAC cluster-admin via Kubernetes RBAC integration - and Virtual Machine Administrator Login on the jumpbox. One group controls both."
  type        = list(string)
}

# --- ACR + Key Vault + Storage ---

variable "registry_name" {
  description = "Globally unique ACR name (alphanumeric only, no hyphens)"
  type        = string
}

variable "vault_name" {
  description = "Globally unique Key Vault name (3-24 characters, alphanumeric and hyphens only)"
  type        = string
}

variable "storage_account_name" {
  description = "Globally unique Storage Account name (3-24 characters, lowercase letters and numbers ONLY)"
  type        = string
}
