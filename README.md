# Capacity Reservation Bot

An Azure automation that tries to buy **On-Demand Capacity Reservations** every hour, degrading gracefully to smaller quantities when Azure can't fulfil the full amount. Keeps state, shows a dashboard, and remembers progress across restarts.

Built for the scenario:

> "I want 50 × `Standard_NV6ads_A10_v5` and 9 × `Standard_NV18ads_A10_v5` in West Europe, but the region is tight so a single big request always fails."

---

## Table of contents

- [What it does](#what-it-does)
- [Architecture](#architecture)
- [The buying strategy (halving degrade)](#the-buying-strategy-halving-degrade)
- [Repo layout](#repo-layout)
- [Prerequisites](#prerequisites)
- [Deploy](#deploy)
- [Configure](#configure)
- [Using it](#using-it)
- [How much does it cost?](#how-much-does-it-cost)
- [What runs where](#what-runs-where)
- [Local development](#local-development)
- [Troubleshooting](#troubleshooting)
- [Tearing it down](#tearing-it-down)

---

## What it does

- Runs an **Azure Function** on a **timer** at the top of every hour.
- On each run, for every SKU target you configured:
  1. Reads what Azure currently has (`instanceView.currentCapacity`).
  2. If the reservation is in a `Failed` state → restores it to a healthy number.
  3. If the target isn't reached yet → tries to buy more with a **halving degrade sequence** (e.g. tries 50, then 25, then 12, then 6, then 3, then 1).
  4. After every success it keeps chipping within the same hour, so you can get multiple partial fulfilments in one run.
- Persists everything in **two Azure Storage tables**:
  - `crState` — one row per SKU with current progress.
  - `crAttempts` — append-only audit log of every API call.
- Exposes an **HTML dashboard** so you can see progress at a glance, and a **JSON endpoint** for scripting.

---

## Architecture

```
Azure subscription
│
├── Resource group: crbot-app-rg
│   ├── Storage account (state tables + Function's own runtime storage)
│   ├── Log Analytics workspace + Application Insights (logs & telemetry)
│   └── Function App (Flex Consumption, Python 3.11, system-assigned MI)
│         ├── Timer trigger  "hourly_buy"     ← runs every hour
│         ├── HTTP POST      /api/run          ← manual trigger (key-protected)
│         ├── HTTP GET       /api/state        ← JSON state
│         └── HTTP GET       /api/dashboard    ← HTML dashboard
│
└── Resource group: crbot-reservations-rg
    └── Capacity Reservation Group "cr-group-we" (regional, West Europe)
          ├── cr-standard-nv6ads-a10-v5     ← grows toward 50
          └── cr-standard-nv18ads-a10-v5    ← grows toward 9
```

- Two resource groups so you can delete the **reservations RG** independently when the workload ends, without touching the app or audit history.
- **Regional CRG** (no zones): Azure picks whichever zone in West Europe has capacity — better odds than pinning to one zone.
- **System-assigned managed identity**: no keys, no connection strings anywhere in code.

---

## The buying strategy (halving degrade)

Given a "how many more do I need" number `N`, the bot generates a shrinking sequence:

```
50 → 25 → 12 → 6 → 3 → 1
```

For each value in the sequence it makes one API call. Behaviour depends on whether the reservation already exists:

- **First run for a SKU (create):** first quantity Azure accepts becomes the reservation size.
- **Subsequent runs (update / PATCH):** first delta Azure accepts is added to the existing capacity, then the loop **continues** with a smaller target — because a partial success doesn't mean the region is out, it just means Azure won't hand out that big a chunk right now.
- The whole hour ends when the full degrade sequence fails end-to-end, or you hit the target, or the safety cap of 32 iterations is hit.

Failed-state safety: if Azure moves the reservation into `Failed` (rare, but possible during capacity pressure), the bot reads `instanceView.currentCapacity` and PATCHes back to that value so the reservation becomes usable again.

---

## Repo layout

```
capacity reservation/
├── azure.yaml                     # azd manifest (infra = terraform, service = api)
├── README.md                      # this file
├── .gitignore
├── infra/                         # Terraform module
│   ├── providers.tf               # azurerm ~> 4.10, random ~> 3.6
│   ├── variables.tf               # inputs (name_prefix, location, targets, ...)
│   ├── main.tf                    # RGs, storage, App Insights, Function App, RBAC
│   ├── outputs.tf                 # values azd surfaces after deploy
│   └── main.tfvars.json           # defaults (edit here to change targets)
└── src/                           # Function App code (Python 3.11)
    ├── function_app.py            # timer + 3 HTTP triggers
    ├── cr_config.py               # env var parsing
    ├── cr_manager.py              # buying strategy, Azure Compute calls
    ├── cr_state.py                # Table Storage state + audit log
    ├── host.json                  # Functions runtime config
    ├── requirements.txt           # Python dependencies
    ├── .funcignore                # files excluded from the deployment package
    └── local.settings.json.example  # template for local `func start`
```

---

## Prerequisites

- Azure subscription with permission to create resource groups and assign roles.
- Quota for the target VM SKUs (capacity reservations still consume quota — check with `az vm list-usage -l westeurope`).
- Tools installed locally:
  - **Azure CLI** — `az login`
  - **Terraform ≥ 1.6** — `terraform version`
  - **Azure Developer CLI (`azd`) ≥ 1.10** — `azd version`
  - **Python 3.11** and **Azure Functions Core Tools v4** (only if you want to run locally)

---

## Deploy

The fastest path uses `azd`:

```powershell
# 1) Sign in
az login
azd auth login

# 2) Create an azd environment (names your deployment; used as a suffix)
azd env new crbot

# 3) Point azd at your subscription and region
azd env set AZURE_SUBSCRIPTION_ID <your-subscription-id>
azd env set AZURE_LOCATION westeurope

# 4) Provision infra AND deploy the Function App code
azd up
```

At the end `azd` prints something like:

```
DASHBOARD_URL         = https://crbot-func-a1b2c3d4.azurewebsites.net/api/dashboard
FUNCTION_APP_NAME     = crbot-func-a1b2c3d4
AZURE_RESOURCE_GROUP  = crbot-app-rg
RESERVATIONS_RESOURCE_GROUP = crbot-reservations-rg
```

Open the dashboard URL in a browser. It auto-refreshes every 60 seconds.

### Manual Terraform-only path

If you don't want to use `azd`:

```powershell
cd infra
terraform init
terraform apply `
  -var="environment_name=crbot" `
  -var-file=main.tfvars.json

# Note the FUNCTION_APP_NAME output, then publish the code:
cd ..\src
func azure functionapp publish <FUNCTION_APP_NAME> --python
```

---

## Configure

Everything you'd normally want to change lives in [infra/main.tfvars.json](infra/main.tfvars.json):

```json
{
  "name_prefix": "crbot",
  "location": "westeurope",
  "reservations_location": "westeurope",
  "capacity_reservation_group_name": "cr-group-we",
  "targets": [
    { "sku": "Standard_NV6ads_A10_v5",  "quantity": 50 },
    { "sku": "Standard_NV18ads_A10_v5", "quantity": 9  }
  ]
}
```

- `targets` — add or remove SKUs as needed. Each SKU becomes one reservation. The bot chases each target independently.
- `name_prefix` — short prefix used in every resource name. Change if you want to run more than one bot in the same subscription.
- Regions — the app can live in a different region than the reservations if you want, but there's no reason to complicate things.

After editing, `azd up` again to apply.

### Change the schedule

The timer uses NCRONTAB. Currently every hour on the hour:

```python
@app.timer_trigger(schedule="0 0 * * * *", ...)   # see src/function_app.py
```

- `0 */30 * * * *` = every 30 minutes
- `0 0 */2 * * *` = every 2 hours
- `0 15 * * * *`  = at :15 of every hour

Redeploy after changing.

---

## Using it

### Dashboard

Open `DASHBOARD_URL`. You'll see:

- **One card per SKU** with progress bar, `confirmed / target`, last outcome, last error.
- **"Recent attempts"** — audit log tail showing every API call the bot made, colour-coded by success/failure.

### JSON state (for scripts)

```powershell
curl https://crbot-func-xxxx.azurewebsites.net/api/state | ConvertFrom-Json
```

Returns config + per-SKU status + the last 100 attempts.

### Manual trigger

To run the buying cycle right now instead of waiting for the next hour:

```powershell
# The function key is on the Function App -> App keys -> _master
$key = az functionapp keys list `
  --name crbot-func-xxxx `
  --resource-group crbot-app-rg `
  --query masterKey -o tsv

curl -X POST "https://crbot-func-xxxx.azurewebsites.net/api/run?code=$key"
```

Returns a JSON summary of what happened.

---

## How much does it cost?

- **Reservations themselves** — you pay the standard on-demand VM rate for each VM instance the bot successfully reserves, whether or not a VM is deployed against it. If the bot gets you 12 out of 50 NV6, you pay for 12 NV6 instance-hours per hour until you either deploy VMs into them or delete the reservation.
- **Function App (Flex Consumption)** — a few pennies per month at this workload (once-an-hour runs with small dashboard traffic).
- **Storage account** — fractions of a cent per month.
- **App Insights** — a few pennies per month at default sampling.

**Total infra cost when idle: ~$1–2/month.** All the money is in the reservations you actually acquire.

Reserved Instances / Savings Plans automatically apply to matching on-demand capacity reservations, so those discounts stack normally.

---

## What runs where

| Concern | Where |
|---|---|
| Hourly buying attempts | Function App timer trigger, top of every hour |
| Progress state | `crState` table in the storage account (one row per SKU) |
| Audit log | `crAttempts` table (one row per API call, partitioned by day) |
| Logs & traces | Application Insights → Log Analytics workspace |
| Buy authority | Function App's managed identity, with **Contributor** on the reservations RG only |
| Storage authority | Same MI with **Storage Blob Data Owner / Queue Data Contributor / Table Data Contributor** on the storage account only |

No secrets, no connection strings, no service principal passwords are ever created or stored.

---

## Local development

```powershell
cd src
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt

# Copy the template and fill in real values (your subscription id, existing RG,
# storage account you have access to).
Copy-Item local.settings.json.example local.settings.json
notepad local.settings.json

# Start the Function host (needs Azurite for local storage emulation)
func start
```

Then hit:

- `POST http://localhost:7071/api/run` to trigger the buy cycle
- `GET  http://localhost:7071/api/dashboard` to open the dashboard
- `GET  http://localhost:7071/api/state` to see the JSON

`DefaultAzureCredential` locally uses whatever you're signed in with (VS Code, `az login`, environment variables).

---

## Troubleshooting

**The dashboard shows `remaining` = target but no attempts appear**
Timer hasn't run yet. Trigger a manual run (see above) or wait for the next hour. First timer fire is at the next `HH:00:00` after deployment.

**Attempts show `AuthorizationFailed` or `Insufficient Privileges`**
The Function's managed identity is missing role assignments. `terraform apply` should have set them; check the RG's IAM blade. The MI needs Contributor on the reservations RG.

**Attempts show `OperationNotAllowed` with a capacity message**
That's the expected "no capacity" answer. The bot will keep trying smaller quantities in the same run and try again next hour.

**Attempts show `QuotaExceeded`**
You need more subscription quota for the VM family. Capacity reservations still count against quota. Request a quota increase in the portal for the target VM family in your region.

**Reservation shows `provisioningState = Failed`**
Azure couldn't fulfil an increase and left the reservation in a bad state. The bot will auto-restore it on the next run by reading `instanceView.currentCapacity` and PATCHing back to that value.

**Function App logs**
Look in Application Insights → `traces`, or run:

```powershell
az functionapp logs tail --name crbot-func-xxxx --resource-group crbot-app-rg
```

---

## Tearing it down

To stop paying for anything:

```powershell
# Deletes ALL resources this project created:
azd down --purge
```

Or, more selectively:

```powershell
# Just stop the reservations (keeps the bot around):
az group delete --name crbot-reservations-rg --yes

# Or just stop the bot (keeps whatever reservations exist):
az group delete --name crbot-app-rg --yes
```

Once the reservations RG is deleted, hourly bills for reserved capacity stop.
