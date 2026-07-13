# =============================================================================
# variables.tf
#
# All input variables for the module live here. Defaults are set so that
# `terraform apply` works out of the box for the West Europe scenario the
# repo is built around. `main.tfvars.json` overrides these values in a
# machine-readable way that azd is happy with.
# =============================================================================

# azd sets this automatically from the current environment name (`azd env new
# <name>`). We use it as a suffix so a single subscription can host multiple
# instances (dev, staging, ...) side by side without name collisions.
variable "environment_name" {
  description = "azd environment name (used as a suffix for resource names)."
  type        = string
}

# Region for the Function App, storage, log analytics, App Insights.
# NOT the region for the reservations - that's `reservations_location` below.
variable "location" {
  description = "Region for the Function App and its supporting resources."
  type        = string
  default     = "westeurope"
}

# Short prefix that all resource names start with, e.g. "crbot" -> "crbot-func-*".
# Kept short because Azure has 24-char caps on storage-account names.
variable "name_prefix" {
  description = "Short lowercase prefix for all resources (3-16 chars)."
  type        = string
  default     = "crbot"

  # Terraform validation block enforces this at plan time - no waiting for
  # Azure to reject an invalid name.
  validation {
    condition     = length(var.name_prefix) >= 3 && length(var.name_prefix) <= 16
    error_message = "name_prefix must be 3-16 characters."
  }
}

# Where the actual capacity reservations will be purchased. Usually the same
# as `location`, but they don't have to be. Only regions with the target VM
# SKUs are valid.
variable "reservations_location" {
  description = "Region where capacity reservations will be purchased."
  type        = string
  default     = "westeurope"
}

# Name of the Capacity Reservation Group (CRG). The CRG is a container -
# no cost, no capacity, just a labelled shelf that holds the per-SKU
# reservations. Passed to the Function App as CR_GROUP_NAME.
variable "capacity_reservation_group_name" {
  description = "Name of the Capacity Reservation Group (CRG) that will hold the reservations."
  type        = string
  default     = "cr-group-we"
}

# The list of (SKU, quantity) targets the bot chases every hour. Encoded as
# JSON when passed to the Function App as CR_TARGETS.
# Add more entries here to reserve additional VM sizes.
variable "targets" {
  description = "Target SKUs and desired quantities. The bot will keep trying to reach these totals."
  type = list(object({
    sku      = string
    quantity = number
  }))
  default = [
    { sku = "Standard_NV6ads_A10_v5", quantity = 50 },
    { sku = "Standard_NV18ads_A10_v5", quantity = 9 }
  ]
}
