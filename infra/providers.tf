terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    # Allow deletion of RGs that contain resources created outside Terraform
    # (like the auto-created App Insights alert rules and subnet NSGs).
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
