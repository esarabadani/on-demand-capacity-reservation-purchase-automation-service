<#
.SYNOPSIS
    Hourly capacity-reservation buyer with halving-degrade strategy.

.DESCRIPTION
    Runs once per hour from an Azure Automation Account. For each SKU listed in
    the "CR-Targets" Automation Variable, tries to grow (or create) a matching
    capacity reservation up to the target quantity. If Azure can't fulfil the
    full amount, retries with N/2, N/4, ..., 1. After any success it loops
    again in the same run to squeeze out more capacity.

    Everything the dashboard needs is stored in Azure itself:
      - Reservation object      : current capacity, provisioning state
      - Automation job output   : the "recent attempts" audit trail
    No storage account, no private endpoint, no VNet.

    Requirements on the Automation Account:
      - System-assigned Managed Identity with Contributor on the reservations RG
      - Az.Accounts + Az.Compute PowerShell modules imported (via Terraform)
      - Automation Variables (set by Terraform):
          CR-SubscriptionId    : Azure subscription id
          CR-ResourceGroup     : reservations RG name
          CR-Location          : reservations region (e.g. germanywestcentral)
          CR-GroupName         : capacity reservation group name
          CR-Targets           : JSON string, e.g.
                                 [{"sku":"Standard_D2s_v3","quantity":5}]
#>

param()

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1) Auth via the Automation Account's managed identity.
#    Connect-AzAccount -Identity works out of the box in Automation runbooks
#    that have "Identity: SystemAssigned" enabled.
# ---------------------------------------------------------------------------
Write-Output "[$(Get-Date -Format o)] Starting hourly cycle"
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null

# ---------------------------------------------------------------------------
# 2) Load config from Automation Variables (set by Terraform).
# ---------------------------------------------------------------------------
$subId         = Get-AutomationVariable -Name 'CR-SubscriptionId'
$rgName        = Get-AutomationVariable -Name 'CR-ResourceGroup'
$defaultRegion = Get-AutomationVariable -Name 'CR-Location'
$groupPrefix   = Get-AutomationVariable -Name 'CR-GroupPrefix'

# Get-AutomationVariable auto-deserializes JSON-valued variables. Depending
# on how CR-Targets was written, we may get back an already-parsed array of
# PSObjects OR still a JSON string. Handle both.
$targetsRaw = Get-AutomationVariable -Name 'CR-Targets'
if ($null -eq $targetsRaw) {
    $targets = @()
} elseif ($targetsRaw -is [System.Collections.IEnumerable] -and $targetsRaw -isnot [string]) {
    $targets = @($targetsRaw)
} elseif ($targetsRaw -is [string]) {
    $targets = @($targetsRaw | ConvertFrom-Json)
} else {
    $targets = @($targetsRaw)
}

Set-AzContext -Subscription $subId | Out-Null

Write-Output "Config: sub=$subId rg=$rgName defaultRegion=$defaultRegion groupPrefix=$groupPrefix"
Write-Output ("Targets ({0}): {1}" -f $targets.Count, (($targets | ForEach-Object {
    $r = if ($_.region) { $_.region } else { $defaultRegion }
    "$($_.sku) x$($_.quantity) in $r"
}) -join ' | '))

# ---------------------------------------------------------------------------
# 3) Helpers
# ---------------------------------------------------------------------------

function Get-DegradeSequence {
    # Halving sequence: e.g. 50 -> 50, 25, 12, 6, 3, 1
    param([int]$N)
    if ($N -le 0) { return @() }
    $seq = [System.Collections.Generic.List[int]]::new()
    $cur = $N
    while ($cur -gt 1) { $seq.Add($cur); $cur = [int][math]::Floor($cur / 2) }
    $seq.Add(1)
    return $seq | Select-Object -Unique
}

function Get-ReservationName {
    param([string]$Sku)
    return "cr-$($Sku.Replace('_','-').ToLower())"
}

function Ensure-Group {
    param([string]$RG, [string]$GroupName, [string]$Location)
    $g = Get-AzCapacityReservationGroup `
            -ResourceGroupName $RG `
            -Name $GroupName `
            -ErrorAction SilentlyContinue
    if ($null -eq $g) {
        Write-Output "Creating capacity reservation group '$GroupName' in $Location"
        New-AzCapacityReservationGroup `
            -ResourceGroupName $RG `
            -Name $GroupName `
            -Location $Location | Out-Null
    }
}

function Get-ReservationSnapshot {
    param([string]$RG, [string]$GroupName, [string]$Sku)
    $name = Get-ReservationName -Sku $Sku
    try {
        $r = Get-AzCapacityReservation `
                -ResourceGroupName $RG `
                -ReservationGroupName $GroupName `
                -Name $name `
                -InstanceView `
                -ErrorAction Stop
    } catch {
        return @{ Exists = $false; Capacity = 0; Current = 0; State = 'None' }
    }
    $cur = $r.Sku.Capacity
    if ($r.InstanceView -and $r.InstanceView.PSObject.Properties['UtilizationInfo']) {
        # currentCapacity lives here in some API versions; fall back to Sku.Capacity.
        $iv = $r.InstanceView
        if ($iv.PSObject.Properties['CurrentCapacity'] -and $iv.CurrentCapacity) {
            $cur = [int]$iv.CurrentCapacity
        }
    }
    return @{
        Exists   = $true
        Capacity = [int]$r.Sku.Capacity
        Current  = [int]$cur
        State    = "$($r.ProvisioningState)"
    }
}

function Try-CreateReservation {
    param([string]$RG, [string]$GroupName, [string]$Sku, [string]$Location, [int]$Qty)
    $name = Get-ReservationName -Sku $Sku
    New-AzCapacityReservation `
        -ResourceGroupName $RG `
        -ReservationGroupName $GroupName `
        -Name $name `
        -Location $Location `
        -Sku $Sku `
        -CapacityToReserve $Qty | Out-Null
    return (Get-ReservationSnapshot -RG $RG -GroupName $GroupName -Sku $Sku)
}

function Try-UpdateReservation {
    param([string]$RG, [string]$GroupName, [string]$Sku, [int]$NewCapacity)
    $name = Get-ReservationName -Sku $Sku
    Update-AzCapacityReservation `
        -ResourceGroupName $RG `
        -ReservationGroupName $GroupName `
        -Name $name `
        -CapacityToReserve $NewCapacity | Out-Null
    return (Get-ReservationSnapshot -RG $RG -GroupName $GroupName -Sku $Sku)
}

# ---------------------------------------------------------------------------
# 4) Per-SKU work loop
#
# Each target may specify its own region. We derive one CRG per region using
# `${groupPrefix}-${region}`. CRGs are created on demand.
# ---------------------------------------------------------------------------

foreach ($t in $targets) {
    $sku    = $t.sku
    $target = [int]$t.quantity
    $region = if ($t.region) { $t.region } else { $defaultRegion }
    $groupName = "$groupPrefix-$region"

    Write-Output "----- SKU $sku in $region (target=$target, group=$groupName) -----"

    # Make sure the region's CRG exists.
    try {
        Ensure-Group -RG $rgName -GroupName $groupName -Location $region
    } catch {
        Write-Output ("ERROR: could not ensure CRG '{0}' in {1}: {2}" -f $groupName, $region, $_.Exception.Message)
        continue
    }

    # Refresh what Azure currently has.
    $snap = Get-ReservationSnapshot -RG $rgName -GroupName $groupName -Sku $sku

    # Track whether we did *any* work this run so the "no new chunks needed"
    # branch below can distinguish "restore only" from "did nothing at all".
    $didRestore = $false

    # If Azure left the reservation in a Failed state, restore to the actual
    # currentCapacity so it becomes usable again.
    if ($snap.Exists -and $snap.State -ieq 'Failed') {
        $safe = [math]::Max($snap.Current, 1)
        Write-Output "Reservation is Failed; restoring to $safe"
        try {
            $snap = Try-UpdateReservation -RG $rgName -GroupName $groupName -Sku $sku -NewCapacity $safe
            Write-Output "Restored. state=$($snap.State) capacity=$($snap.Current)"
            $didRestore = $true
        } catch {
            Write-Output "ERROR: restore failed: $($_.Exception.Message)"
            continue
        }
    }

    # Chip loop: keep buying more within this run until the degrade sequence
    # fails end-to-end or we hit the target. Safety cap = 32 iterations.
    for ($iter = 0; $iter -lt 32; $iter++) {
        $confirmed = if ($snap.Exists) { $snap.Current } else { 0 }
        $remaining = [math]::Max($target - $confirmed, 0)
        if ($remaining -le 0) {
            # Three cases:
            #   - iter=0 AND no restore -> nothing happened this run at all
            #   - iter=0 AND restore    -> we restored a Failed reservation but bought nothing new
            #   - iter>0                -> we bought at least one chunk this run and hit target
            if ($iter -eq 0 -and -not $didRestore) {
                Write-Output "Target already reached ($confirmed/$target). No action needed."
            } elseif ($iter -eq 0 -and $didRestore) {
                Write-Output "Reservation restored to healthy state ($confirmed/$target). No new capacity needed."
            } else {
                Write-Output "Target reached ($confirmed/$target). Done."
            }
            break
        }

        Write-Output "confirmed=$confirmed remaining=$remaining"
        $anyOK = $false

        foreach ($qty in (Get-DegradeSequence -N $remaining)) {
            if ($snap.Exists) {
                $newCap = $snap.Current + $qty
                try {
                    Write-Output "  GROW +$qty (to $newCap)..."
                    $snap = Try-UpdateReservation -RG $rgName -GroupName $groupName -Sku $sku -NewCapacity $newCap
                    if ($snap.State -ieq 'Failed') { throw "Update returned Failed state" }
                    Write-Output "    OK. capacity=$($snap.Current)"
                    $anyOK = $true
                    break
                } catch {
                    Write-Output "    FAIL: $($_.Exception.Message)"
                    # If update pushed reservation to Failed, restore before retrying smaller delta.
                    $refresh = Get-ReservationSnapshot -RG $rgName -GroupName $groupName -Sku $sku
                    if ($refresh.State -ieq 'Failed') {
                        $safe = [math]::Max($refresh.Current, 1)
                        Write-Output "    Restoring to $safe after Failed state"
                        try { $snap = Try-UpdateReservation -RG $rgName -GroupName $groupName -Sku $sku -NewCapacity $safe }
                        catch { Write-Output "    RESTORE FAILED: $($_.Exception.Message)" }
                    }
                }
            } else {
                try {
                    Write-Output "  CREATE $qty..."
                    $snap = Try-CreateReservation -RG $rgName -GroupName $groupName -Sku $sku -Location $region -Qty $qty
                    Write-Output "    OK. capacity=$($snap.Current)"
                    $anyOK = $true
                    break
                } catch {
                    Write-Output "    FAIL: $($_.Exception.Message)"
                }
            }
        }

        if (-not $anyOK) {
            Write-Output "Whole degrade sequence failed. Stopping for this SKU."
            break
        }
    }
}

Write-Output "[$(Get-Date -Format o)] Cycle finished"

# ---------------------------------------------------------------------------
# Force a clean process exit.
# PowerShell 7.2 Automation runbooks sometimes stay in "Running" for hours
# after the script logically completes because the Azure SDK's HTTP clients
# keep background threads alive. `Disconnect-AzAccount` releases them; the
# `exit 0` then guarantees the runbook worker returns.
# ---------------------------------------------------------------------------
try { Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null } catch {}
exit 0
