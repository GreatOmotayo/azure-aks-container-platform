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
    systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
    systemctl stop unattended-upgrades 2>/dev/null || true

    wait_for_apt() {
      while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
         || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
         || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        sleep 5
      done
    }

    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get install -y git unzip gnupg software-properties-common
    wait_for_apt
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash || { echo "Azure CLI install failed"; exit 1; }
    az aks install-cli --install-location /usr/local/bin/kubectl --kubelogin-install-location /usr/local/bin/kubelogin
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get install -y terraform
    wait_for_apt
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash || { echo "Helm install failed"; exit 1; }
    gpg -k
    gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
    echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | tee /etc/apt/sources.list.d/k6.list
    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get install -y k6
    curl -fsSL -o /tmp/velero.tar.gz https://github.com/vmware-tanzu/velero/releases/download/v1.15.0/velero-v1.15.0-linux-amd64.tar.gz
    tar -xvf /tmp/velero.tar.gz -C /tmp
    mv /tmp/velero-v1.15.0-linux-amd64/velero /usr/local/bin/velero
    rm -rf /tmp/velero.tar.gz /tmp/velero-v1.15.0-linux-amd64
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
