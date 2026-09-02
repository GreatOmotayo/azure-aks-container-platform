variable "environment" {
  description = "Environment name - used to name the identity and federated credential so a future staging promotion doesn't collide with these resource names"
  type        = string
  default     = "production"
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "The dedicated app resource group (rg-aks-app) - same as every other application-tier identity in this project"
  type        = string
}

variable "aks_oidc_issuer_url" {
  description = "The AKS cluster's OIDC issuer URL (from modules/aks output) - the trust anchor this federated credential validates against, same mechanism as Aduke's and the worker's identities"
  type        = string
}

variable "storage_account_id" {
  description = "Resource ID of the Storage Account holding the velero-backups container"
  type        = string
}

variable "velero_backup_container_name" {
  description = "the container's name, used to build a container-level RBAC scope. Was removed when the container briefly moved to manual creation (an ordering problem: this role assignment ran before a manually-created container existed). Now that the container is back to Terraform management within the same apply, that ordering problem is gone - Terraform's own dependency graph (via referencing module.storage's output) ensures the container exists before this scope string is resolved."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}