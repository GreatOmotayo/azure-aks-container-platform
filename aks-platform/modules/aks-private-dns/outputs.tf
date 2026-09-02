output "zone_id" {
  description = "Resource ID of the custom private DNS zone - passed to the AKS cluster module's private_dns_zone_id, so the cluster resolves through this zone instead of a AKS managed"
  value       = azurerm_private_dns_zone.aks.id
}

output "zone_name" {
  description = "FQDN of the zone - useful for post-deploy validation"
  value       = azurerm_private_dns_zone.aks.name
}