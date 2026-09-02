variable "environment" {
  description = "Environment name"
  type        = string
  default     = "production"
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "The dedicated app resource group"
  type        = string
}

variable "app_namespace" {
  description = "Kubernetes namespace Aduke and the worker deploy into"
  type        = string
  default     = "app"
}

variable "aks_oidc_issuer_url" {
  description = "The AKS cluster's OIDC issuer URL (from modules/aks output)"
  type        = string
}

variable "key_vault_id" {
  description = "Resource ID of the key Vault both apps read the storage account name from"
  type        = string
}

variable "storage_account_id" {
  description = "Resource ID of the storage account both apps read/write against"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}