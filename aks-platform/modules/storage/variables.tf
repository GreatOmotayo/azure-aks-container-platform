variable "storage_account_name" {
  description = "Globally unique Storage Account name"
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "The dedicated app resource app - same as ACR and Key Vault"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}