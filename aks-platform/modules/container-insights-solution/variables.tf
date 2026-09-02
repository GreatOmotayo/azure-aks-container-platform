variable "location" {
  type = string
}

variable "workspace_resource_group_name" {
  description = "The resource group containing the network project's Log Analytics workspace - a Log Analytics Solution must be created in the SAME resource group as its target workspace, a real Azure requirement, not a choice made here"
  type        = string
}

variable "log_analytics_workspace_id" {
  description = "From the network project's remote state - the workspace this Solution attaches Container Insights to"
  type        = string
}

variable "log_analytics_workspace_name" {
  description = "From the network project's remote state - the plain workspace name (not its resource ID)"
  type        = string
}

variable "tags" {
  description = "Must include whatever tag key the Landing Zone project's baseline-platform policy requires (confirmed: CostCenter) - this is the entire point of this module existing"
  type        = map(string)
  default     = {}
}