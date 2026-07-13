# =============================================================================
# main.tf
#
# All Azure resources for the capacity-reservation-bot. Deployed as ONE
# Terraform module. Layout (top to bottom):
#
#   1. locals               - derived names + tags
#   2. resource groups      - one for the app, one for the reservations
#   3. storage account      - runtime + crState / crAttempts tables
#   4. log analytics + app insights
#   5. service plan (FC1)   - Flex Consumption
#   6. function app         - the bot, with system-assigned managed identity
#   7. RBAC role assignments - so the MI can do its job
#
# WHY TWO RESOURCE GROUPS?
# ------------------------
# The app RG holds infrastructure that lives forever (storage, insights, the
# Function App itself). The reservations RG holds the CRG and its children,
# which you may want to delete once the workload is over. Keeping them
# separate means you can `az group delete -n <reservations RG>` safely.
# =============================================================================

# -----------------------------------------------------------------------------
# 1) locals - derived names and tags
# -----------------------------------------------------------------------------
locals {
  # Deterministic 8-char suffix from a hash of the prefix + azd env name.
  # This makes resource names stable across `terraform apply` runs but unique
  # per environment.
  suffix = substr(sha1("${var.name_prefix}-${var.environment_name}"), 0, 8)

  # Resource group names.
  app_rg_name          = "${var.name_prefix}-app-rg"
  reservations_rg_name = "${var.name_prefix}-reservations-rg"

  # Storage account: lowercase, alphanumeric, 3-24 chars.
  # We strip hyphens and truncate to be safe.
  storage_account_name = substr(replace(lower("${var.name_prefix}st${local.suffix}"), "-", ""), 0, 24)

  # Everything else uses the prefix + short suffix pattern.
  log_workspace_name = "${var.name_prefix}-log-${local.suffix}"
  app_insights_name  = "${var.name_prefix}-ai-${local.suffix}"
  plan_name          = "${var.name_prefix}-plan-${local.suffix}"
  function_app_name  = "${var.name_prefix}-func-${local.suffix}"

  # Blob container that holds the deployment package (azd zips ./src into it).
  deployment_container = "deploymentpackage"

  # Every resource gets the azd-env-name tag so `azd` can identify which
  # environment they belong to. Extra tags (like azd-service-name) are
  # merged in per-resource below.
  tags = {
    "azd-env-name" = var.environment_name
  }
}

# -----------------------------------------------------------------------------
# 2) Resource groups
# -----------------------------------------------------------------------------

# App RG - long-lived infra (Function App, storage, insights).
resource "azurerm_resource_group" "app" {
  name     = local.app_rg_name
  location = var.location
  tags     = local.tags
}

# Reservations RG - lives separately so it's easy to nuke when the workload
# ends without touching the Function App or the audit history.
resource "azurerm_resource_group" "reservations" {
  name     = local.reservations_rg_name
  location = var.reservations_location
  tags     = local.tags
}

# -----------------------------------------------------------------------------
# 3) Storage account - runtime storage + our two state tables
# -----------------------------------------------------------------------------
resource "azurerm_storage_account" "sa" {
  name                = local.storage_account_name
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location

  account_tier             = "Standard" # cheapest tier; we're storing tiny rows
  account_replication_type = "LRS"      # single-region redundancy is enough
  account_kind             = "StorageV2"

  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  public_network_access_enabled   = true # simpler; tighten with PE later if needed

  # Flex Consumption Functions currently require the storage account key
  # to be enabled for the internal runtime, even though our app code uses
  # managed identity for everything. This is a known temporary constraint.
  shared_access_key_enabled = true

  # Prefer Entra ID auth in the portal / SDK by default (managed identity path).
  default_to_oauth_authentication = true

  tags = local.tags
}

# Blob container that receives the deployment package uploaded by `azd deploy`.
resource "azurerm_storage_container" "deploy" {
  name                  = local.deployment_container
  storage_account_id    = azurerm_storage_account.sa.id
  container_access_type = "private"
}

# crState = one row per SKU, current status. See cr_state.py.
resource "azurerm_storage_table" "state" {
  name                 = "crState"
  storage_account_name = azurerm_storage_account.sa.name
}

# crAttempts = append-only audit log. See cr_state.py.
resource "azurerm_storage_table" "attempts" {
  name                 = "crAttempts"
  storage_account_name = azurerm_storage_account.sa.name
}

# -----------------------------------------------------------------------------
# 4) Log Analytics workspace + Application Insights
#
# Log Analytics is the underlying data store; App Insights is the APM layer
# that Functions writes to. We wire App Insights to the workspace ("workspace-
# based App Insights") which is the current recommended pattern.
# -----------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "log" {
  name                = local.log_workspace_name
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  sku                 = "PerGB2018"
  retention_in_days   = 30 # 30 days is enough for this workload; adjust freely
  tags                = local.tags
}

resource "azurerm_application_insights" "ai" {
  name                = local.app_insights_name
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.log.id
  tags                = local.tags
}

# -----------------------------------------------------------------------------
# 5) Flex Consumption service plan
#
# SKU "FC1" = the Flex Consumption tier. Scales to zero, per-invocation billing.
# Perfect fit for once-an-hour code.
# -----------------------------------------------------------------------------
resource "azurerm_service_plan" "plan" {
  name                = local.plan_name
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = local.tags
}

# -----------------------------------------------------------------------------
# 6) Function App itself
#
# Flex Consumption uses a distinct resource type
# (azurerm_function_app_flex_consumption). Deployment package is stored in the
# blob container we created above; authentication to it is via the Function's
# managed identity (so no keys inside the app).
# -----------------------------------------------------------------------------
resource "azurerm_function_app_flex_consumption" "func" {
  name                = local.function_app_name
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  service_plan_id     = azurerm_service_plan.plan.id

  # Deployment package location + auth method.
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.sa.primary_blob_endpoint}${azurerm_storage_container.deploy.name}"
  storage_authentication_type = "SystemAssignedIdentity"

  # Runtime.
  runtime_name           = "python"
  runtime_version        = "3.11"
  instance_memory_in_mb  = 2048 # generous, but keeps a nice cold-start budget
  maximum_instance_count = 40   # cap so a bug can't scale to $$$

  https_only = true

  # System-assigned managed identity - our permission spine.
  identity {
    type = "SystemAssigned"
  }

  # Wires the app to App Insights.
  site_config {
    application_insights_connection_string = azurerm_application_insights.ai.connection_string
  }

  # The app settings the Python code reads via os.environ (see cr_config.py).
  # Everything is a string in Azure - CR_TARGETS is JSON-encoded here.
  app_settings = {
    # Managed-identity-aware runtime storage - no connection string needed.
    "AzureWebJobsStorage__accountName"      = azurerm_storage_account.sa.name
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.ai.connection_string

    # Business-logic settings.
    "CR_TARGET_SUBSCRIPTION_ID" = data.azurerm_client_config.current.subscription_id
    "CR_TARGET_RESOURCE_GROUP"  = azurerm_resource_group.reservations.name
    "CR_LOCATION"               = var.reservations_location
    "CR_GROUP_NAME"             = var.capacity_reservation_group_name
    "CR_TARGETS"                = jsonencode(var.targets)
    "CR_STATE_TABLE"            = "crState"
    "CR_ATTEMPTS_TABLE"         = "crAttempts"
    "CR_STORAGE_ACCOUNT"        = azurerm_storage_account.sa.name
  }

  # Tag consumed by `azd` to figure out which Function App to deploy to.
  # Must match the service name in azure.yaml ("api").
  tags = merge(local.tags, {
    "azd-service-name" = "api"
  })

  # Ensure the deployment container and both tables exist before the Function
  # App tries to reach them for the first time.
  depends_on = [
    azurerm_storage_container.deploy,
    azurerm_storage_table.state,
    azurerm_storage_table.attempts,
  ]
}

# Data source used above to read the current subscription id.
data "azurerm_client_config" "current" {}

# -----------------------------------------------------------------------------
# 7) RBAC role assignments
#
# The Function's managed identity needs:
#   - data-plane roles on the storage account (read/write blobs, queues, tables)
#   - Contributor on the reservations RG (create/update the CRG and reservations)
#
# We use the well-known Azure built-in role NAMES. Terraform resolves them to
# GUIDs automatically. principal_id comes from the Function App's identity[0]
# block above.
# -----------------------------------------------------------------------------

# Runtime host uses blobs for deployment package + host state.
resource "azurerm_role_assignment" "blob_owner" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Runtime host uses queues for internal triggers (Functions internals).
resource "azurerm_role_assignment" "queue_contrib" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Our code uses tables for crState / crAttempts.
resource "azurerm_role_assignment" "table_contrib" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Table Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Contributor on the reservations RG lets the Function create/update the CRG
# and its child capacity reservations. Scope is limited to that one RG.
resource "azurerm_role_assignment" "reservations_contributor" {
  scope                = azurerm_resource_group.reservations.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
