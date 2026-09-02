variable "location" {
  description = "Azure region - used to build the required zone name (privatelink.<region>.azmk8s.io)"
  type        = string
}

variable "resource_group_name" {
  description = "Resource group to create the private DNS zone in"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. \"production\", \"non-production\") - used to name the workload VNet link so a future staging promotion doesn't collide with the production link's name"
  type        = string
  default     = "production"
}

variable "vnet_id" {
  description = "This project's own standalone VNet resource ID - both the jumpbox and the AKS nodes live in it, so only one VNet link is needed now."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}