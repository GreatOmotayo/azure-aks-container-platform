variable "environment" {
  description = "Environment name - used to name the VM and NIC"
  type        = string
  default     = "production"
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "Resource group the jumpbox deploys into - the hub's resource group, since this VM lives in the hub VNet's shared-services subnet"
  type        = string
}

variable "subnet_id" {
  description = "The hub's shared services subnet ID - the jumpbox lives in the hub"
  type        = string
}

variable "vm_size" {
  description = "VM size - small and cheap, since this machine only runs kubectl/az CLI sessions"
  type        = string
  default     = "Standard_D2s_v6"
}

variable "ssh_public_key" {
  description = "Public key only - the matching private key stays on your own machine and is never passed into Terraform"
  type        = string
}

variable "admin_group_object_ids" {
  description = "Entra ID group object ID(s) granted 'Virtual Machine Administrator Login' on this VM"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}
