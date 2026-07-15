# =============================================================================
# main.tf
#
# Deploys:
#   1. App RG + Reservations RG
#   2. Automation Account with system-assigned MI
#      - PowerShell 7.2 runbook: buy-reservations.ps1
#      - Az.Accounts + Az.Compute modules imported
#      - Hourly schedule + job schedule link
#      - Config stored as Automation Variables
#   3. VNet + subnet + NSG + Public IP + NIC for the dashboard VM
#      - NSG restricted to var.dashboard_allowed_ip on ports 22 and 80
#   4. Ubuntu VM with cloud-init that installs pwsh + Az module + nginx
#      + a systemd timer that regenerates the HTML every minute
#   5. RBAC:
#      - Automation MI: Contributor on reservations RG
#      - VM MI: Reader on reservations RG + Reader on Automation Account
#
# All state lives in Azure itself:
#   - Current capacity : the reservation object
#   - Attempt history  : Automation job output (persisted forever by Automation)
# No storage account, no private endpoint, no VNet integration.
# =============================================================================

data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# 1) Locals
# -----------------------------------------------------------------------------
locals {
  suffix = substr(sha1("${var.name_prefix}-${data.azurerm_client_config.current.subscription_id}"), 0, 8)

  app_rg_name          = "${var.name_prefix}-app-rg"
  reservations_rg_name = "${var.name_prefix}-reservations-rg"

  automation_account_name = "${var.name_prefix}-aa-${local.suffix}"
  runbook_name            = "buy-reservations"
  schedule_name           = "hourly"

  vnet_name   = "${var.name_prefix}-vnet-${local.suffix}"
  subnet_name = "vm-subnet"
  nsg_name    = "${var.name_prefix}-nsg-${local.suffix}"
  pip_name    = "${var.name_prefix}-pip-${local.suffix}"
  nic_name    = "${var.name_prefix}-nic-${local.suffix}"
  vm_name     = "${var.name_prefix}-vm-${local.suffix}"

  targets_json = jsonencode(var.targets)

  # Where the customer's Cloud Shell will fetch bootstrap files from when
  # installing on an existing VM. Kept as a local so a fork can override once.
  bootstrap_repo_raw = "https://raw.githubusercontent.com/esarabadani/on-demand-capacity-reservation-purchase-automation-service/main"

  # Managed identity principalId of whichever VM will host the dashboard.
  # When Terraform creates the VM we read it from that resource; when the
  # customer brings their own VM they pass it as an input.
  dashboard_vm_principal_id = var.use_existing_vm ? var.existing_vm_principal_id : try(azurerm_linux_virtual_machine.vm[0].identity[0].principal_id, "")

  tags = {
    project = "capacity-reservation-bot"
  }
}

# -----------------------------------------------------------------------------
# 2) Resource groups
# -----------------------------------------------------------------------------
resource "azurerm_resource_group" "app" {
  name     = local.app_rg_name
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "reservations" {
  name     = local.reservations_rg_name
  location = var.reservations_location
  tags     = local.tags
}

# -----------------------------------------------------------------------------
# 3) Automation Account + runbook + schedule
# -----------------------------------------------------------------------------
resource "azurerm_automation_account" "aa" {
  name                = local.automation_account_name
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name
  sku_name            = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags
}

# Import the required Az PowerShell modules (runtime = PowerShell 7.2).
# Az.Accounts must be imported before Az.Compute (dependency).
resource "azurerm_automation_module" "az_accounts" {
  name                    = "Az.Accounts"
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Az.Accounts/3.0.4"
  }
}

resource "azurerm_automation_module" "az_compute" {
  name                    = "Az.Compute"
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name

  module_link {
    uri = "https://www.powershellgallery.com/api/v2/package/Az.Compute/8.4.0"
  }

  depends_on = [azurerm_automation_module.az_accounts]
}

# The runbook - PowerShell 7.2, script content loaded from disk.
resource "azurerm_automation_runbook" "buy" {
  name                    = local.runbook_name
  location                = azurerm_resource_group.app.location
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  log_verbose             = false
  log_progress            = false
  description             = "Hourly capacity-reservation buyer with halving-degrade strategy."
  runbook_type            = "PowerShell72"

  content = file("${path.module}/../runbook/buy-reservations.ps1")

  depends_on = [
    azurerm_automation_module.az_accounts,
    azurerm_automation_module.az_compute,
  ]
}

# Configuration values, stored as Automation Variables (not encrypted; nothing
# secret in here). The runbook reads them via Get-AutomationVariable.
resource "azurerm_automation_variable_string" "sub_id" {
  name                    = "CR-SubscriptionId"
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  value                   = data.azurerm_client_config.current.subscription_id
}

resource "azurerm_automation_variable_string" "res_rg" {
  name                    = "CR-ResourceGroup"
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  value                   = azurerm_resource_group.reservations.name
}

resource "azurerm_automation_variable_string" "location" {
  name                    = "CR-Location"
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  value                   = var.reservations_location
}

resource "azurerm_automation_variable_string" "group_prefix" {
  name                    = "CR-GroupPrefix"
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  value                   = var.capacity_reservation_group_prefix
}

resource "azurerm_automation_variable_string" "targets" {
  name                    = "CR-Targets"
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  value                   = local.targets_json
}

# Hourly schedule. Interval defined by var.runbook_schedule_hours (default 1).
resource "azurerm_automation_schedule" "hourly" {
  name                    = local.schedule_name
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  frequency               = "Hour"
  interval                = var.runbook_schedule_hours
  timezone                = "UTC"
  # Start at least 5 minutes in the future - Azure requires this.
  start_time  = timeadd(timestamp(), "10m")
  description = "Fires the buy-reservations runbook every ${var.runbook_schedule_hours}h."

  lifecycle {
    ignore_changes = [start_time]
  }
}

# Wire the schedule to the runbook (this is what actually causes it to run).
resource "azurerm_automation_job_schedule" "hourly" {
  resource_group_name     = azurerm_resource_group.app.name
  automation_account_name = azurerm_automation_account.aa.name
  schedule_name           = azurerm_automation_schedule.hourly.name
  runbook_name            = azurerm_automation_runbook.buy.name
}

# Automation MI needs Contributor on the reservations RG so it can create
# and update capacity reservations.
resource "azurerm_role_assignment" "aa_reservations_contributor" {
  scope                = azurerm_resource_group.reservations.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_automation_account.aa.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# -----------------------------------------------------------------------------
# 4) VNet + subnet + NSG + Public IP + NIC
#
# All of the resources in this section are ONLY created when
# use_existing_vm = false. When the customer brings their own VM, they use
# their own VNet/NSG/PIP.
# -----------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  count               = var.use_existing_vm ? 0 : 1
  name                = local.vnet_name
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name
  address_space       = ["10.30.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  count                = var.use_existing_vm ? 0 : 1
  name                 = local.subnet_name
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.vnet[0].name
  address_prefixes     = ["10.30.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  count               = var.use_existing_vm ? 0 : 1
  name                = local.nsg_name
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name

  security_rule {
    name                       = "AllowSshFromAllowedIp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.dashboard_allowed_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHttpFromAllowedIp"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = var.dashboard_allowed_ip
    destination_address_prefix = "*"
  }

  tags = local.tags
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  count                     = var.use_existing_vm ? 0 : 1
  subnet_id                 = azurerm_subnet.vm[0].id
  network_security_group_id = azurerm_network_security_group.vm[0].id
}

resource "azurerm_public_ip" "vm" {
  count               = var.use_existing_vm ? 0 : 1
  name                = local.pip_name
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  # Some subscriptions return an empty ip_tags object even when we don't set
  # one, which causes needless replaces on subsequent applies. Ignore it.
  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "vm" {
  count               = var.use_existing_vm ? 0 : 1
  name                = local.nic_name
  location            = azurerm_resource_group.app.location
  resource_group_name = azurerm_resource_group.app.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm[0].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm[0].id
  }

  tags = local.tags
}

# -----------------------------------------------------------------------------
# 5) Cloud-init to bootstrap nginx + pwsh + the dashboard renderer
# -----------------------------------------------------------------------------
locals {
  render_script = file("${path.module}/../dashboard/render-dashboard.ps1")
  nginx_conf    = file("${path.module}/../dashboard/nginx-crbot.conf")
  timer_unit    = file("${path.module}/../dashboard/crbot-dashboard.timer")
  service_unit  = file("${path.module}/../dashboard/crbot-dashboard.service")

  cloud_init = <<-EOT
    #cloud-config
    package_update: true
    package_upgrade: false
    packages:
      - nginx
      - curl
      - ca-certificates
      - gnupg
      - apt-transport-https
      - software-properties-common

    write_files:
      - path: /opt/crbot/render-dashboard.ps1
        permissions: "0755"
        encoding: b64
        content: ${base64encode(local.render_script)}

      - path: /etc/nginx/sites-available/crbot
        encoding: b64
        content: ${base64encode(local.nginx_conf)}

      - path: /etc/systemd/system/crbot-dashboard.service
        encoding: b64
        content: ${base64encode(local.service_unit)}

      - path: /etc/systemd/system/crbot-dashboard.timer
        encoding: b64
        content: ${base64encode(local.timer_unit)}

      - path: /etc/crbot/dashboard.env
        permissions: "0600"
        content: |
          CR_SUB_ID=${data.azurerm_client_config.current.subscription_id}
          CR_RES_RG=${azurerm_resource_group.reservations.name}
          CR_GROUP_PREFIX=${var.capacity_reservation_group_prefix}
          CR_DEFAULT_REGION=${var.reservations_location}
          CR_TARGETS_JSON=${jsonencode(local.targets_json)}
          CR_AUTOMATION_RG=${azurerm_resource_group.app.name}
          CR_AUTOMATION_ACCOUNT=${local.automation_account_name}
          CR_RUNBOOK_NAME=${local.runbook_name}

      - path: /var/www/html/index.html
        content: |
          <!doctype html><html><body><h1>Capacity Reservation Dashboard</h1>
          <p>Booting... first render in ~90 seconds.</p></body></html>

    runcmd:
      # 1) Install PowerShell 7 for Ubuntu 24.04
      - curl -sL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
      - echo "deb [arch=amd64] https://packages.microsoft.com/ubuntu/24.04/prod noble main" > /etc/apt/sources.list.d/microsoft-prod.list
      - apt-get update
      - apt-get install -y powershell
      # 2) Install Az PowerShell modules (only the ones we actually use).
      - pwsh -NoProfile -Command "Install-Module Az.Accounts -Force -AllowClobber -Scope AllUsers -Repository PSGallery"
      - pwsh -NoProfile -Command "Install-Module Az.Compute -Force -AllowClobber -Scope AllUsers -Repository PSGallery"
      - pwsh -NoProfile -Command "Install-Module Az.Automation -Force -AllowClobber -Scope AllUsers -Repository PSGallery"
      # 3) nginx: enable our config, disable the default site.
      - ln -sf /etc/nginx/sites-available/crbot /etc/nginx/sites-enabled/crbot
      - rm -f /etc/nginx/sites-enabled/default
      - systemctl reload nginx
      # 4) systemd timer for the dashboard renderer.
      - systemctl daemon-reload
      - systemctl enable --now crbot-dashboard.timer
  EOT
}

# -----------------------------------------------------------------------------
# 6) The VM itself  (only when use_existing_vm = false)
# -----------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "vm" {
  count                           = var.use_existing_vm ? 0 : 1
  name                            = local.vm_name
  resource_group_name             = azurerm_resource_group.app.name
  location                        = azurerm_resource_group.app.location
  size                            = var.vm_size
  admin_username                  = var.dashboard_admin_username
  admin_password                  = var.dashboard_admin_password
  disable_password_authentication = false

  network_interface_ids = [azurerm_network_interface.vm[0].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  custom_data = base64encode(local.cloud_init)
  tags        = local.tags
}

# VM MI: Reader on reservations RG (see reservation state) + Reader on the
# Automation Account (see job history). Same three role assignments regardless
# of whether we created the VM or the customer brought their own.
resource "azurerm_role_assignment" "vm_reservations_reader" {
  scope                = azurerm_resource_group.reservations.id
  role_definition_name = "Reader"
  principal_id         = local.dashboard_vm_principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "vm_automation_reader" {
  scope                = azurerm_automation_account.aa.id
  role_definition_name = "Reader"
  principal_id         = local.dashboard_vm_principal_id
  principal_type       = "ServicePrincipal"
}

# Automation Operator lets the VM's MI list job outputs. Reader alone isn't
# enough because job output is a sub-operation on the Automation Account.
resource "azurerm_role_assignment" "vm_automation_job_operator" {
  scope                = azurerm_automation_account.aa.id
  role_definition_name = "Automation Operator"
  principal_id         = local.dashboard_vm_principal_id
  principal_type       = "ServicePrincipal"
}
