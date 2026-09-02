variable "environment" {
  type    = string
  default = "production"
}

variable "location" {
  type    = string
  default = "centralus"
}

variable "resource_group_name" {
  type = string
}

variable "vnet_cidr" {
  description = "Address space for this project's own standalone VNet - no longer a spoke of any hub network"
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
  description = "SSH to the jumpbox is only ever reachable from this specific IP/CIDR. Update this if your own IP changes."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
