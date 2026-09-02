variable "vault_name" {
  description = "Globally unique key Vault name"
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "The dedicated app resource group"
  type        = string
}

variable "admin_group_object_ids" {
  description = "Entra ID group object ID(s) granted key Vault Administrator"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}