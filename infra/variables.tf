# ------------------------------------------------------------------------------
# variables.tf - inputs for the capacity-reservation-bot Terraform module.
# ------------------------------------------------------------------------------

variable "name_prefix" {
  description = "Short prefix (3-16 chars, lowercase) used in every resource name."
  type        = string
  default     = "crbot"

  validation {
    condition     = length(var.name_prefix) >= 3 && length(var.name_prefix) <= 16
    error_message = "name_prefix must be 3-16 characters."
  }
}

variable "location" {
  description = "Region for the Automation Account, VM, VNet, and their RG."
  type        = string
  default     = "germanywestcentral"
}

variable "reservations_location" {
  description = "Default region for capacity reservations. Used when a target does not set its own `region`."
  type        = string
  default     = "germanywestcentral"
}

variable "capacity_reservation_group_prefix" {
  description = "Prefix for the Capacity Reservation Groups. Actual CRG name = `<prefix>-<region>`, so multiple regions each get their own CRG."
  type        = string
  default     = "cr-group"
}

variable "targets" {
  description = <<-EOT
    SKU targets. The bot tries to grow each reservation up to `quantity`.
    Each target can pick its own region — if `region` is null, the target
    inherits `reservations_location`. Regions are independent: two SKUs in
    different regions land in two different CRGs.
  EOT
  type = list(object({
    sku      = string
    quantity = number
    region   = optional(string)
  }))
  default = [
    { sku = "Standard_D2as_v7", quantity = 5, region = "westeurope" },
    { sku = "Standard_D2ads_v7", quantity = 3, region = "westeurope" }
  ]
}

variable "runbook_schedule_hours" {
  description = "How often the runbook runs. 1 = every hour."
  type        = number
  default     = 1
}

# ---- Dashboard VM ----
variable "use_existing_vm" {
  description = <<-EOT
    Choose between two dashboard hosting modes:
      false = Terraform creates a fresh Ubuntu VM (with public IP + NSG) and installs everything via cloud-init.
      true  = Skip VM creation. You bring an existing Ubuntu VM. Terraform still grants that VM's managed identity the RBAC it needs. After apply, you run the printed `az vm run-command` to install nginx + PowerShell + the dashboard on your VM.
  EOT
  type        = bool
  default     = false
}

variable "existing_vm_resource_id" {
  description = "Full resource ID of the existing Ubuntu VM. Required when use_existing_vm=true. Get with: az vm show --name <vm> --resource-group <rg> --query id -o tsv"
  type        = string
  default     = ""
}

variable "existing_vm_principal_id" {
  description = "Object ID of the existing VM's system-assigned managed identity. Required when use_existing_vm=true. Enable + get it with: az vm identity assign --ids <vm-id> --query systemAssignedIdentity -o tsv"
  type        = string
  default     = ""
}

variable "dashboard_admin_username" {
  description = "Admin username for the new VM. Ignored when use_existing_vm=true."
  type        = string
  default     = "azureuser"
}

variable "dashboard_admin_password" {
  description = "Admin password for the new VM (12-72 chars, must satisfy Azure complexity: upper, lower, digit, symbol). Ignored when use_existing_vm=true; supply any placeholder in that case."
  type        = string
  sensitive   = true
  default     = "NotUsed-IfExistingVm-1234!"

  validation {
    condition     = length(var.dashboard_admin_password) >= 12 && length(var.dashboard_admin_password) <= 72
    error_message = "dashboard_admin_password must be 12-72 characters long."
  }
}

variable "dashboard_allowed_ip" {
  description = "Public IP (in CIDR form, e.g. '203.0.113.42/32') allowed to reach the new VM on ports 22 and 80. Ignored when use_existing_vm=true."
  type        = string
  default     = "0.0.0.0/32"
}

variable "vm_size" {
  description = "VM size for the new dashboard VM. Ignored when use_existing_vm=true."
  type        = string
  default     = "Standard_D2as_v7"
}
