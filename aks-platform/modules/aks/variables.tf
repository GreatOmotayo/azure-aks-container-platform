variable "environment" {
  description = "Environment name - used to name the cluster, its identity and its DNS prefix"
  type        = string
  default     = "production"
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "Resource group for the cluster itself"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version"
  type        = string
  default     = null
}

# --- Networking ---
variable "subnet_id" {
  description = "The pre-provisioned AKS node subnet from the network project's remote state"
  type        = string
}

variable "pod_cidr" {
  description = "Overlay pod CIDR - a private range that never touches real VNet address space"
  type        = string
  default     = "10.244.0.0/16"
}

variable "service_cidr" {
  type    = string
  default = "10.245.0.0/16"
}

variable "dns_service_ip" {
  description = "Must be an address inside service_cidr"
  type        = string
  default     = "10.245.0.10"
}

variable "private_dns_zone_id" {
  description = "Resource ID of the custom private DNS zone from the aks-private-dns module"
  type        = string
}

# --- Identity, RBAC, Observability
variable "admin_group_object_ids" {
  description = "Entra ID group object ID(s) granted Azure RBAC cluster admin via Kubernetes RBAC integration"
  type        = list(string)
}

variable "log_analytics_workspace_id" {
  description = "The network project's centralized log analytics workspace"
  type        = string
}

# ---- Node pool ---

variable "system_node_vm_size" {
  type = string
}

variable "system_node_count" {
  type = string
}

variable "user_node_vm_size" {
  type = string
}

variable "user_node_min_count" {
  type = string
}

variable "user_node_max_count" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}