# =============================================================================
# providers.tf
#
# Declares which Terraform version and which provider versions this module
# needs. `terraform init` reads this file and downloads the matching plugins.
# =============================================================================

terraform {
  # Minimum Terraform CLI version. The Flex Consumption resource
  # (azurerm_function_app_flex_consumption) needs a recent CLI.
  required_version = ">= 1.6.0"

  required_providers {
    # The main Azure provider. We pin the 4.10 series (matches azurerm 4.x
    # which is the current stable line at the time of writing).
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }

    # Not strictly needed today, but kept for potential future use of
    # `random_string` for name suffixes. Cheap to include.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # Enables the default set of provider features. If you want to tweak
  # deletion behaviour (e.g. purge_soft_delete_on_destroy for Key Vault),
  # that goes inside this block.
  features {}

  # subscription_id is intentionally not set here - azd sets ARM_SUBSCRIPTION_ID
  # in the environment before running terraform, and the provider will pick it
  # up automatically.
}
