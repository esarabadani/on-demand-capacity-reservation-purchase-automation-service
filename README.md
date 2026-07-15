# On-Demand Capacity Reservation Purchase Automation Service

A hands-off Azure automation that **buys on-demand capacity reservations every hour** using a halving-degrade strategy — great for scarce VM SKUs in tight regions. Ships with a small web dashboard you can host on a brand-new VM the tool creates for you, **or on an Ubuntu VM you already own**.

Everything installs from **Azure Cloud Shell** — no local tooling required. Only prerequisites are `git`, `terraform`, `az` (all preinstalled in Cloud Shell).

---

## Table of contents

- [What it does](#what-it-does)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Path A — deploy everything (Terraform creates a new VM)](#path-a--deploy-everything-terraform-creates-a-new-vm)
- [Path B — use an existing Ubuntu VM you already own](#path-b--use-an-existing-ubuntu-vm-you-already-own)
- [Configuring the SKUs to buy](#configuring-the-skus-to-buy)
- [Using the dashboard](#using-the-dashboard)
- [The buying strategy in one paragraph](#the-buying-strategy-in-one-paragraph)
- [Costs](#costs)
- [Uninstall / cleanup](#uninstall--cleanup)
- [Troubleshooting](#troubleshooting)

---

## What it does

- Every hour an **Azure Automation runbook** (PowerShell 7.2) tries to reach a target of *N* instances for each configured VM SKU, in each configured region.
- If Azure can't give you the full amount, the runbook halves: asks for `N/2`, then `N/4`, … down to `1`. After every success it keeps chipping toward the target within the same run.
- If a `PATCH` puts the reservation into a `Failed` state, the runbook auto-restores it to the last healthy capacity — no manual intervention.
- A small dashboard renders live progress cards + a per-job history table, colour-coded by outcome (Target reached / Already reserved / Restored / No capacity / Failed).
- State lives entirely in Azure objects (reservations + Automation job history). **No storage account, no database, no private endpoints.**

---

## Architecture

```
Reservations RG
 └── One Capacity Reservation Group per region
      └── One reservation per configured SKU
           (grows toward its target over time)

App RG
 ├── Automation Account (system-assigned managed identity)
 │    ├── runbook: buy-reservations.ps1
 │    ├── hourly schedule + job schedule link
 │    └── Automation Variables: CR-SubscriptionId, CR-ResourceGroup,
 │                              CR-Location, CR-GroupPrefix, CR-Targets
 └── Ubuntu VM (either newly created or one you already own)
      ├── System-assigned MI
      │    ├── Reader on Reservations RG
      │    └── Reader + Automation Operator on Automation Account
      └── nginx + PowerShell 7 + systemd timer
           renders /var/www/html/index.html every minute from live ARM
```

**RBAC granted by Terraform:**

| Identity | Scope | Role |
|---|---|---|
| Automation Account MI | Reservations RG | Contributor (creates/updates CRGs + reservations) |
| Dashboard VM MI | Reservations RG | Reader |
| Dashboard VM MI | Automation Account | Reader + Automation Operator (to read job output) |

---

## Prerequisites

- An Azure subscription. The signed-in user (you, in Cloud Shell) needs:
  - **Contributor** on the subscription (or on the two resource groups the tool creates) — to deploy resources.
  - **User Access Administrator** or **Owner** on those scopes — to assign the RBAC roles above.
- Enough VM quota in the target region for the SKUs you want to reserve. Capacity reservations count against quota.
- **Path B only:** an existing Ubuntu 22.04 or 24.04 VM in the same subscription, reachable on port 80 from wherever you'll open the dashboard.

---

## Path A — deploy everything (Terraform creates a new VM)

Use this when the customer has **no VM available** for the dashboard.

### 1. Open Cloud Shell

Go to https://shell.azure.com/ (or click the `>_` icon at the top of the Azure portal). Choose **Bash**.

### 2. Confirm you're in the right subscription

```bash
az account show --query "{name:name, id:id}" -o table

# If wrong subscription:
az account set --subscription "<subscription-name-or-id>"
```

### 3. Clone the repo

```bash
git clone https://github.com/esarabadani/on-demand-capacity-reservation-purchase-automation-service.git
cd on-demand-capacity-reservation-purchase-automation-service/infra
```

### 4. Configure inputs

Two required inputs: your public IP (for the NSG allow rule) and a VM admin password.

```bash
export TF_VAR_dashboard_allowed_ip="$(curl -s https://api.ipify.org)/32"
read -srp "Choose a VM admin password (12-72 chars, upper+lower+digit+symbol): " PW; echo
export TF_VAR_dashboard_admin_password="$PW"
```

### 5. Deploy

```bash
terraform init
terraform apply -auto-approve
```

Takes ~5 minutes. Outputs include `DASHBOARD_URL`. Open it in a browser (only your IP is allowed).

### 6. Trigger a first run (optional)

The scheduled runbook fires at the top of the next hour. If you want progress on the dashboard sooner:

```bash
AA=$(terraform output -raw AUTOMATION_ACCOUNT)
RG=$(terraform output -raw AZURE_RESOURCE_GROUP)
az automation runbook start --automation-account-name "$AA" --resource-group "$RG" --name buy-reservations
```

---

## Path B — use an existing Ubuntu VM you already own

Use this when the customer says **"I already have a VM, don't create one."**

### 1. Open Cloud Shell (same as above)

### 2. Find your VM's resource ID

```bash
VM_RG="<your-vm's-resource-group>"
VM_NAME="<your-vm's-name>"
VM_ID=$(az vm show --name "$VM_NAME" --resource-group "$VM_RG" --query id -o tsv)
echo "VM ID: $VM_ID"
```

### 3. Enable a system-assigned managed identity on the VM

Terraform needs the MI's principal ID to grant it RBAC roles.

```bash
VM_PRINCIPAL_ID=$(az vm identity assign --ids "$VM_ID" --query systemAssignedIdentity -o tsv)
echo "VM MI principal ID: $VM_PRINCIPAL_ID"
```

*(If a MI already exists, this command is idempotent and just returns it.)*

### 4. Clone the repo

```bash
git clone https://github.com/esarabadani/on-demand-capacity-reservation-purchase-automation-service.git
cd on-demand-capacity-reservation-purchase-automation-service/infra
```

### 5. Deploy (existing-VM mode)

```bash
export TF_VAR_use_existing_vm=true
export TF_VAR_existing_vm_resource_id="$VM_ID"
export TF_VAR_existing_vm_principal_id="$VM_PRINCIPAL_ID"

terraform init
terraform apply -auto-approve
```

Takes ~3 minutes (no VM to create).

### 6. Install the dashboard software on your VM

Terraform prints a ready-to-run command as `BOOTSTRAP_COMMAND`:

```bash
eval "$(terraform output -raw BOOTSTRAP_COMMAND)"
```

That command:
1. Downloads `bootstrap-vm.sh` from the repo.
2. Runs it on your VM via `az vm run-command invoke` (no SSH needed).
3. The script installs nginx + PowerShell 7 + the render script + a systemd timer, then writes `/etc/crbot/dashboard.env` and starts everything.

Takes another ~3-5 minutes (PowerShell modules are slow to install).

### 7. Open port 80 to your IP

If your VM's NSG doesn't already allow inbound HTTP from your address:

```bash
MY_IP="$(curl -s https://api.ipify.org)/32"
VM_NIC=$(az vm show --ids "$VM_ID" --query "networkProfile.networkInterfaces[0].id" -o tsv)
VM_SUBNET=$(az network nic show --ids "$VM_NIC" --query "ipConfigurations[0].subnet.id" -o tsv)
NSG_ID=$(az network vnet subnet show --ids "$VM_SUBNET" --query "networkSecurityGroup.id" -o tsv)
if [[ -n "$NSG_ID" ]]; then
  az network nsg rule create --nsg-name "$(basename $NSG_ID)" --resource-group "$(echo $NSG_ID | cut -d/ -f5)" \
    --name AllowCrbotHttp --priority 200 --direction Inbound --access Allow \
    --protocol Tcp --source-address-prefixes "$MY_IP" --destination-port-ranges 80
fi
```

### 8. Visit the dashboard

```bash
VM_IP=$(az vm show --ids "$VM_ID" -d --query publicIps -o tsv)
echo "Dashboard: http://${VM_IP}/"
```

If your VM has no public IP, use its private IP via VPN or the Azure Bastion — the dashboard is a plain HTTP page nginx serves on port 80.

---

## Configuring the SKUs to buy

Edit `infra/variables.tf` (`targets` variable):

```hcl
variable "targets" {
  default = [
    { sku = "Standard_D2as_v7",  quantity = 5, region = "germanywestcentral" },
    { sku = "Standard_D2ads_v7", quantity = 3, region = "germanywestcentral" },
    # add more here
  ]
}
```

- `sku` — full VM size string (must be capacity-reservation-eligible; see `az vm list-skus`).
- `quantity` — total instances you eventually want reserved.
- `region` — optional; falls back to `reservations_location` (default: germanywestcentral).

Then re-apply:

```bash
terraform apply -auto-approve
```

The runbook picks up the new list on its next scheduled run (or you can trigger it manually as in step 6 above).

---

## Using the dashboard

Cards at the top:
- **N / M** — current reserved vs target.
- Green **All reserved** pill when at target, amber **Partially reserved** when growing, grey **Not created yet** before the first run.

Recent runbook jobs table (bottom):
- One row **per SKU per job**.
- **Outcome** column:
  - **Target reached** — bot bought new capacity this run to hit the target.
  - **Already reserved** — target was already met on arrival, no work done.
  - **Restored to healthy state** — a previous PATCH left the reservation `Failed`, this run fixed it.
  - **No capacity available** — halving sequence failed end-to-end this run.
  - **Failed** — the runbook itself crashed.
- **Attempts / Reserved / Failed** — API-call counts per SKU.
- **Details** — either `capacity now = N` (on success) or the truncated Azure error message.

The page auto-refreshes every 60 seconds and reads live from Azure — nothing is cached.

---

## The buying strategy in one paragraph

Every hour, for each configured SKU, the bot reads what Azure already has and computes `remaining = target − current`. If `remaining > 0`, it asks Azure for `remaining` more instances. If Azure refuses, it halves and tries again (`remaining/2`, `/4`, … `1`). **After every success it starts a fresh round**: recompute `remaining`, ask again. That keeps chipping capacity within a single hour whenever Azure is willing to hand out smaller chunks. If a `PATCH` puts the reservation into `Failed` state (rare but possible during capacity pressure), the bot restores it to its last healthy capacity in the same run before trying smaller sizes. When either the target is reached or an entire halving sequence returns nothing, the runbook exits and waits for the next hour.

---

## Costs

Rough monthly Germany West Central estimates, USD:

| Resource | Cost/month | Notes |
|---|---|---|
| Automation Account | free | Runbook execution minutes at these volumes are within the free tier. |
| Runbook job hosting | ~$0.05 | ~30 minutes/month of PowerShell 7.2 execution. |
| New dashboard VM (Path A only) | ~$60 | `Standard_D2as_v7` running 24/7. Reduce with `vm_size` variable. |
| Public IP for new VM (Path A only) | ~$3.60 | Standard SKU, static. |
| **Capacity reservations themselves** | **PAYG rate of each reserved VM size × 730h** | You pay for every instance you actually manage to reserve, whether or not a VM is attached. |

**The last row is the big number** — reserving 5 × `Standard_D2as_v7` is roughly 5 × their hourly rate × 730 hours. Reserved-Instance discounts you already have will offset that.

---

## Uninstall / cleanup

**Path A (Terraform created the VM):**

```bash
cd on-demand-capacity-reservation-purchase-automation-service/infra
terraform destroy -auto-approve
```

That deletes the app RG (VM, nginx, Automation) and the reservations RG (all reservations — you stop paying immediately).

**Path B (existing VM):**

Terraform destroys everything it created (Automation + role assignments), but **your VM stays, still running nginx + the timer.** To wipe it:

```bash
# On your VM (over SSH or Cloud Shell run-command):
sudo systemctl disable --now crbot-dashboard.timer crbot-dashboard.service
sudo rm -rf /opt/crbot /etc/crbot
sudo rm -f /etc/systemd/system/crbot-dashboard.service /etc/systemd/system/crbot-dashboard.timer
sudo rm -f /etc/nginx/sites-enabled/crbot /etc/nginx/sites-available/crbot
sudo systemctl reload nginx
```

Then either:

```bash
# Reservations only:
az group delete --name crbot-reservations-rg --yes

# All Terraform-created infra:
terraform destroy -auto-approve
```

---

## Troubleshooting

### Dashboard shows the "Booting..." placeholder for more than 5 minutes

On the VM check `/var/log/cloud-init-output.log` (Path A) or the run-command output from step 6 (Path B). Most common cause: the `Az.*` PowerShell modules failed to install because of a proxy or restricted egress. Fix by running the install command yourself:

```bash
sudo pwsh -Command "Install-Module Az.Accounts, Az.Compute, Az.Automation -Force -Scope AllUsers"
sudo systemctl start crbot-dashboard.service
```

### Runbook status stuck on `Running` for hours

Should not happen with the current code (the runbook calls `Disconnect-AzAccount` + `exit 0`). If it does, stop it manually in the portal and check for an unhandled exception in a recent code edit.

### Reservation says `Failed` state in the portal

Not urgent. Your existing capacity is still yours. The next hourly run will restore it automatically. If you want it fixed now, start the runbook manually (see Path A step 6).

### Cloud Shell command `az vm run-command invoke ... --scripts @/tmp/crbot-bootstrap.sh` returns quickly with `Enable succeeded` but the dashboard is still the placeholder

Wait 3-5 minutes — the run-command finishes when it *dispatches* the script, not when the script itself finishes. The `Az.*` PowerShell module install is what takes the time.

### Can't reach the dashboard from your browser but `curl` from Cloud Shell works

Your browser is likely egressing from a different public IP than the shell (VPN, split tunnel, etc.). Add that IP to the NSG rule or re-run step 4 with your browser's IP.

---

**Questions or issues?** Open a GitHub issue on this repo.
