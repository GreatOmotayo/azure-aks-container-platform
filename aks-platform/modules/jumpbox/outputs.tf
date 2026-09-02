output "public_ip_address" {
  description = "The jumpbox's public IP - used for direct SSH connection now that Bastion is gone. See docs/VALIDATION-PLAN.md Section 0 for the exact connection command."
  value       = azurerm_public_ip.jumpbox.ip_address
}

output "vm_name" {
  value = azurerm_linux_virtual_machine.jumpbox.name
}
