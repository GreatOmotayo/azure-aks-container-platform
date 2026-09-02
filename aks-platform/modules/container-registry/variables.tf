variable "registry_name" {
  description = "Globally unique ACR name"
  type        = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  description = "The dedicated app resource group"
  type        = string
}

variable "kubelet_identity_object_id" {
  description = "The AKS cluster kubelet identity - this is specifically the identity AKS uses to pull images onto node"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}