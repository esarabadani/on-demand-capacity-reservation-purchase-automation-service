#!/usr/bin/env bash
# =============================================================================
# bootstrap-vm.sh
#
# Installs the capacity-reservation dashboard on an existing Ubuntu VM.
# You do NOT run this locally. It's meant to be executed on the target VM by
# the Azure agent via `az vm run-command invoke --scripts @bootstrap-vm.sh`.
#
# When invoked that way, Azure passes every `--parameters KEY=VALUE` you gave
# as a positional argument to this script. We turn each one into an env var,
# then use those to write /etc/crbot/dashboard.env.
#
# Required parameters (all of them):
#   CR_SUB_ID              Azure subscription id
#   CR_RES_RG              Reservations resource group name
#   CR_GROUP_PREFIX        Capacity reservation group name prefix
#   CR_DEFAULT_REGION      Default region when a target omits `region`
#   CR_AUTOMATION_RG       Resource group of the Automation Account
#   CR_AUTOMATION_ACCOUNT  Automation Account name
#   CR_RUNBOOK_NAME        Runbook name (usually: buy-reservations)
#
# Optional:
#   CRBOT_REPO_RAW         Base URL to fetch the dashboard files from.
#                          Defaults to the public GitHub raw URL of this repo.
#   CR_ALLOWED_IP          Comma-separated IPs/CIDRs allowed to reach nginx.
#                          If unset, we rely on Azure NSG / firewall to filter.
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ---- Turn `KEY=VALUE` positional args into env vars ---------------------
for kv in "$@"; do
    if [[ "$kv" == *"="* ]]; then
        export "$kv"
    fi
done

CRBOT_REPO_RAW="${CRBOT_REPO_RAW:-https://raw.githubusercontent.com/esarabadani/on-demand-capacity-reservation-purchase-automation-service/main}"

# ---- Sanity check --------------------------------------------------------
missing=()
for v in CR_SUB_ID CR_RES_RG CR_GROUP_PREFIX CR_DEFAULT_REGION \
         CR_AUTOMATION_RG CR_AUTOMATION_ACCOUNT CR_RUNBOOK_NAME; do
    [[ -z "${!v:-}" ]] && missing+=("$v")
done
if (( ${#missing[@]} > 0 )); then
    echo "ERROR: missing required parameters: ${missing[*]}" >&2
    echo "Pass them via --parameters KEY=VALUE ..." >&2
    exit 2
fi

log() { echo -e "\033[1;36m[crbot]\033[0m $*"; }

# ---- Ensure the VM has a system-assigned managed identity ----------------
# (Terraform can't set this on a VM it didn't create. We only bootstrap the
# software here — the customer must have run `az vm identity assign` before
# `terraform apply` so the MI existed for the RBAC step.)
if ! curl -s -H "Metadata: true" --max-time 3 \
       "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
       > /dev/null; then
    log "WARNING: no managed identity token from IMDS. Dashboard will fail to read Azure."
    log "         Run: az vm identity assign --ids <this-vm> ; then re-apply Terraform."
fi

# ---- 1) Install nginx, PowerShell 7, curl ------------------------------
log "Installing OS packages (nginx, powershell, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg apt-transport-https software-properties-common nginx

# Detect Ubuntu codename to pick the right MS package repo.
. /etc/os-release
UBUNTU_CODENAME="${VERSION_CODENAME:-noble}"

if ! command -v pwsh >/dev/null 2>&1; then
    log "Adding Microsoft package repo and installing PowerShell 7..."
    curl -sL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor \
        | tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null
    echo "deb [arch=amd64] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod ${UBUNTU_CODENAME} main" \
        > /etc/apt/sources.list.d/microsoft-prod.list
    apt-get update -qq
    apt-get install -y -qq powershell
fi

# ---- 2) Install the Az PowerShell modules the render script needs ----------
log "Installing Az PowerShell modules (Az.Accounts, Az.Compute, Az.Automation)..."
pwsh -NoProfile -Command '
    $ErrorActionPreference="Stop"
    if (-not (Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue)) { }
    foreach ($m in @("Az.Accounts","Az.Compute","Az.Automation")) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Install-Module $m -Force -AllowClobber -Scope AllUsers -Repository PSGallery
        }
    }
'

# ---- 3) Pull the four files from GitHub and place them ---------------------
log "Fetching dashboard files from ${CRBOT_REPO_RAW}..."
mkdir -p /opt/crbot /etc/crbot
curl -fsSL "${CRBOT_REPO_RAW}/dashboard/render-dashboard.ps1"       -o /opt/crbot/render-dashboard.ps1
curl -fsSL "${CRBOT_REPO_RAW}/dashboard/nginx-crbot.conf"           -o /etc/nginx/sites-available/crbot
curl -fsSL "${CRBOT_REPO_RAW}/dashboard/crbot-dashboard.service"    -o /etc/systemd/system/crbot-dashboard.service
curl -fsSL "${CRBOT_REPO_RAW}/dashboard/crbot-dashboard.timer"      -o /etc/systemd/system/crbot-dashboard.timer
chmod 755 /opt/crbot/render-dashboard.ps1

# ---- 4) Write the env file the systemd unit will load ----------------------
log "Writing /etc/crbot/dashboard.env..."
cat > /etc/crbot/dashboard.env <<EOF
CR_SUB_ID=${CR_SUB_ID}
CR_RES_RG=${CR_RES_RG}
CR_GROUP_PREFIX=${CR_GROUP_PREFIX}
CR_DEFAULT_REGION=${CR_DEFAULT_REGION}
CR_AUTOMATION_RG=${CR_AUTOMATION_RG}
CR_AUTOMATION_ACCOUNT=${CR_AUTOMATION_ACCOUNT}
CR_RUNBOOK_NAME=${CR_RUNBOOK_NAME}
EOF
chmod 600 /etc/crbot/dashboard.env

# ---- 5) Placeholder index so nginx has something to serve immediately ------
mkdir -p /var/www/html
if [[ ! -f /var/www/html/index.html ]] || grep -q "Booting" /var/www/html/index.html 2>/dev/null; then
    cat > /var/www/html/index.html <<'HTML'
<!doctype html><html><body style="font-family:system-ui;padding:24px">
<h1>Capacity Reservation Dashboard</h1>
<p>Booting... first render in ~90 seconds.</p>
</body></html>
HTML
fi

# ---- 6) Enable our nginx site, disable the default -------------------------
log "Configuring nginx..."
ln -sf /etc/nginx/sites-available/crbot /etc/nginx/sites-enabled/crbot
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx || systemctl restart nginx

# ---- 7) Enable + start the render timer ------------------------------------
log "Enabling crbot-dashboard.timer..."
systemctl daemon-reload
systemctl enable --now crbot-dashboard.timer

# ---- 8) Kick off one render right now so the page shows real data ----------
log "Running first render..."
systemctl start crbot-dashboard.service || true
sleep 10
systemctl status crbot-dashboard.service --no-pager | head -6 || true

log "Done. Open http://<this-vm-public-ip>/ from an allowed IP."
