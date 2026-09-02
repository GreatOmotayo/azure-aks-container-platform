# --- Public IP ---
resource "azurerm_public_ip" "jumpbox" {
  name                = "pip-jumpbox-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# --- Network interface --- 
resource "azurerm_network_interface" "jumpbox" {
  name                = "nic-jumpbox-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.jumpbox.id
  }

  tags = var.tags
}

# --- The VM itself ---
resource "azurerm_linux_virtual_machine" "jumpbox" {
  name                = "vm-jumpbox-${var.environment}"
  location            = var.location
  resource_group_name = var.resource_group_name
  size                = var.vm_size
  admin_username      = "azureuser"
  lifecycle {
    prevent_destroy = true
  }

  network_interface_ids           = [azurerm_network_interface.jumpbox.id]
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Installs az CLI and kubectl at boot, so the VM is immediately usable
  # for cluster access the moment it's provisioned 
  custom_data = base64encode(<<-EOF
    #!/bin/bash
    wait_for_apt() {
      while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
        sleep 5
      done
    }

    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get install -y git unzip gnupg software-properties-common
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
    az aks install-cli --install-location /usr/local/bin/kubectl --kubelogin-install-location /usr/local/bin/kubelogin
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get install -y terraform
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  EOF
  )

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

# --- Azure AD login extension --- 
resource "azurerm_virtual_machine_extension" "aad_login" {
  name                       = "AADSSHLoginForLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.jumpbox.id
  publisher                  = "Microsoft.Azure.ActiveDirectory"
  type                       = "AADSSHLoginForLinux"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

# --- Access control --- 
resource "azurerm_role_assignment" "jumpbox_aad_login" {
  for_each = toset(var.admin_group_object_ids)

  scope                = azurerm_linux_virtual_machine.jumpbox.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = each.value
}
