output "solution_id" {
  description = "Referenced by modules/aks's depends_on, so the cluster's oms_agent is guaranteed to find this already-tagged Solution resource rather than racing to create its own untagged one"
  value       = azurerm_log_analytics_solution.container_insights.id
}