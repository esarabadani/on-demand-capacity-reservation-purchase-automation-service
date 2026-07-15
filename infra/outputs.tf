# =============================================================================
# outputs.tf
# =============================================================================

output "AUTOMATION_ACCOUNT" {
  description = "Automation Account holding the runbook and job history."
  value       = azurerm_automation_account.aa.name
}

output "AZURE_RESOURCE_GROUP" {
  description = "Resource group holding the Automation Account (and the new VM, if any)."
  value       = azurerm_resource_group.app.name
}

output "RESERVATIONS_RESOURCE_GROUP" {
  description = "Resource group holding the Capacity Reservation Groups."
  value       = azurerm_resource_group.reservations.name
}

# ---------------- Outputs for the NEW-VM path -------------------------------
output "DASHBOARD_URL" {
  description = "Dashboard URL when Terraform created the VM. Empty when use_existing_vm=true."
  value       = var.use_existing_vm ? "" : "http://${azurerm_public_ip.vm[0].ip_address}/"
}

output "DASHBOARD_PUBLIC_IP" {
  description = "Public IP of the new VM. Empty when use_existing_vm=true."
  value       = var.use_existing_vm ? "" : azurerm_public_ip.vm[0].ip_address
}

output "DASHBOARD_SSH" {
  description = "SSH command for the new VM. Empty when use_existing_vm=true."
  value       = var.use_existing_vm ? "" : "ssh ${var.dashboard_admin_username}@${azurerm_public_ip.vm[0].ip_address}"
}

# ---------------- Outputs for the EXISTING-VM path --------------------------
# The customer copy-pastes this command into Cloud Shell. It downloads the
# bootstrap script and runs it on the target VM via `az vm run-command`.
output "BOOTSTRAP_COMMAND" {
  description = "Cloud Shell command to install nginx + PowerShell + the dashboard on your existing VM. Empty when use_existing_vm=false."
  value = var.use_existing_vm ? trimspace(<<-EOT
    curl -fsSL ${local.bootstrap_repo_raw}/dashboard/bootstrap-vm.sh -o /tmp/crbot-bootstrap.sh && \
    az vm run-command invoke \
      --ids ${var.existing_vm_resource_id} \
      --command-id RunShellScript \
      --scripts @/tmp/crbot-bootstrap.sh \
      --parameters \
        CR_SUB_ID=${data.azurerm_client_config.current.subscription_id} \
        CR_RES_RG=${azurerm_resource_group.reservations.name} \
        CR_GROUP_PREFIX=${var.capacity_reservation_group_prefix} \
        CR_DEFAULT_REGION=${var.reservations_location} \
        CR_AUTOMATION_RG=${azurerm_resource_group.app.name} \
        CR_AUTOMATION_ACCOUNT=${local.automation_account_name} \
        CR_RUNBOOK_NAME=${local.runbook_name}
  EOT
  ) : ""
}
