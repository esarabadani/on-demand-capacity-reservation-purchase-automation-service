# =============================================================================
# outputs.tf
#
# Values exported by this Terraform module.
#
# azd reads outputs whose names are ALL_UPPER_SNAKE_CASE and copies them into
# the environment (`azd env get-values`) so you can pipe them into follow-up
# commands. Anything you'd want to know after `azd up` finishes goes here.
# =============================================================================

output "AZURE_LOCATION" {
  description = "Region the app was deployed to."
  value       = var.location
}

output "AZURE_RESOURCE_GROUP" {
  description = "Resource group holding the Function App and its dependencies."
  value       = azurerm_resource_group.app.name
}

output "RESERVATIONS_RESOURCE_GROUP" {
  description = "Resource group holding the Capacity Reservation Group and reservations."
  value       = azurerm_resource_group.reservations.name
}

output "FUNCTION_APP_NAME" {
  description = "Name of the Function App running the bot."
  value       = azurerm_function_app_flex_consumption.func.name
}

output "FUNCTION_APP_URL" {
  description = "Base URL of the Function App."
  value       = "https://${azurerm_function_app_flex_consumption.func.default_hostname}"
}

output "DASHBOARD_URL" {
  description = "Direct link to the dashboard endpoint."
  value       = "https://${azurerm_function_app_flex_consumption.func.default_hostname}/api/dashboard"
}

output "STORAGE_ACCOUNT_NAME" {
  description = "Storage account that holds the state tables and deployment package."
  value       = azurerm_storage_account.sa.name
}
