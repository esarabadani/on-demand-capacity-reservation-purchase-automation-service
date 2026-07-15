<#
.SYNOPSIS
    Regenerates /var/www/html/index.html for the capacity reservation dashboard.

.DESCRIPTION
    Runs every minute as a systemd timer on the dashboard VM. Reads current
    reservation state directly from ARM (no storage account) and the recent
    runbook job history (with per-job output summary) from the Automation
    Account, then writes a plain HTML file that nginx serves.

    The VM's system-assigned managed identity must have:
      - Reader on the reservations RG (to see reservations)
      - Reader on the Automation Account (to see job history)
      - Automation Job Operator on the Automation Account (to read job output)

    Configuration comes from environment variables set by cloud-init:
      CR_SUB_ID, CR_RES_RG, CR_GROUP_NAME,
      CR_AUTOMATION_RG, CR_AUTOMATION_ACCOUNT, CR_RUNBOOK_NAME

    IMPORTANT: The target SKU list is NOT read from cloud-init any more.
    Instead we read it live from the "CR-Targets" Automation Variable, so
    the dashboard is always in sync with what the runbook is buying.
#>

param()

$ErrorActionPreference = 'Stop'

# ---- Config from cloud-init env vars ----
$subId         = $env:CR_SUB_ID
$rgName        = $env:CR_RES_RG
$groupPrefix   = $env:CR_GROUP_PREFIX
$defaultRegion = $env:CR_DEFAULT_REGION
$aaRg          = $env:CR_AUTOMATION_RG
$aaName        = $env:CR_AUTOMATION_ACCOUNT
$runbookName   = $env:CR_RUNBOOK_NAME
$outputPath    = '/var/www/html/index.html'

# ---- Auth via the VM's managed identity ----
Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity -WarningAction SilentlyContinue | Out-Null
Set-AzContext -Subscription $subId -WarningAction SilentlyContinue | Out-Null

# Simple HTML escaper (no System.Web dependency on Linux pwsh).
function HtmlEnc([string]$s) {
    if ($null -eq $s) { return '' }
    return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

# ---- Read the *live* target list from the Automation Variable ----
# This is the single source of truth. Changing it in the portal instantly
# flows through to the dashboard on the next render.
$targets = @()
try {
    $tv = Get-AzAutomationVariable -ResourceGroupName $aaRg `
             -AutomationAccountName $aaName -Name 'CR-Targets' -ErrorAction Stop
    # Get-AzAutomationVariable auto-deserializes the stored JSON. Depending on
    # how the variable was set, .Value may already be an array of PSObjects,
    # OR still a JSON string that we need to parse ourselves.
    if ($null -eq $tv -or $null -eq $tv.Value) {
        $targets = @()
    } elseif ($tv.Value -is [System.Collections.IEnumerable] -and $tv.Value -isnot [string]) {
        $targets = @($tv.Value)
    } elseif ($tv.Value -is [string]) {
        $targets = @($tv.Value | ConvertFrom-Json)
    } else {
        # Single object case.
        $targets = @($tv.Value)
    }
} catch {
    Write-Warning "Could not read CR-Targets variable: $($_.Exception.Message)"
}

# ---- Collect reservation snapshots ----
$rows = @()
foreach ($t in $targets) {
    $sku    = $t.sku
    $target = [int]$t.quantity
    $region = if ($t.region) { "$($t.region)" } else { $defaultRegion }
    $groupName = "$groupPrefix-$region"
    $name   = "cr-$($sku.Replace('_','-').ToLower())"

    $cur       = 0
    $rawState  = 'NotCreated'
    $status    = 'Not created yet'
    $statusCls = 'idle'
    try {
        $r = Get-AzCapacityReservation `
                -ResourceGroupName $rgName `
                -ReservationGroupName $groupName `
                -Name $name `
                -InstanceView `
                -ErrorAction Stop
        $cur      = [int]$r.Sku.Capacity
        $rawState = "$($r.ProvisioningState)"
        switch -Regex ($rawState) {
            '^Succeeded$'  { $status = if ($cur -ge $target) { 'All reserved' } else { 'Partially reserved' }; $statusCls = if ($cur -ge $target) { 'ok' } else { 'work' }; break }
            '^Creating$'   { $status = 'Creating...';             $statusCls = 'work'; break }
            '^Updating$'   { $status = 'Updating...';             $statusCls = 'work'; break }
            '^Failed$'     { $status = 'Failed (will auto-restore next run)'; $statusCls = 'bad'; break }
            default        { $status = $rawState;                 $statusCls = 'work' }
        }
    } catch {
        $status    = 'Not created yet'
        $statusCls = 'idle'
    }
    $pct = if ($target -gt 0) { [int](100 * $cur / $target) } else { 0 }
    $rows += [pscustomobject]@{
        Sku       = $sku
        Region    = $region
        Group     = $groupName
        Target    = $target
        Confirmed = $cur
        Remaining = [math]::Max($target - $cur, 0)
        Percent   = $pct
        RawState  = $rawState
        Status    = $status
        StatusCls = $statusCls
    }
}

# ---- Collect recent runbook jobs ----
$jobs = @()
try {
    $jobs = Get-AzAutomationJob `
              -ResourceGroupName $aaRg `
              -AutomationAccountName $aaName `
              -RunbookName $runbookName `
              -ErrorAction Stop |
            Sort-Object CreationTime -Descending |
            Select-Object -First 15
} catch {
    Write-Warning "Could not fetch jobs: $($_.Exception.Message)"
}

# Fetch and parse the stdout of a single job to build per-SKU summaries.
# Returns @{ Verdict, VerdictCls, Skus = @(@{ Sku, Region, Attempts, Successes, Failures, LastCapacity, Verdict, VerdictCls }) }.
function Get-JobSummary($job) {
    $overall = [pscustomobject]@{
        Attempts     = 0
        Successes    = 0
        Failures     = 0
        Verdict      = ''
        VerdictCls   = 'idle'
        Skus         = @()   # ordered list of per-SKU summaries
    }
    if (-not $job) { return $overall }

    $output = ''
    try {
        $recs = Get-AzAutomationJobOutput `
                    -ResourceGroupName $aaRg `
                    -AutomationAccountName $aaName `
                    -Id $job.JobId `
                    -Stream 'Any' `
                    -ErrorAction SilentlyContinue
        $lines = @()
        foreach ($rec in $recs) {
            try {
                $r = Get-AzAutomationJobOutputRecord `
                        -ResourceGroupName $aaRg `
                        -AutomationAccountName $aaName `
                        -JobId $job.JobId `
                        -Id $rec.StreamRecordId `
                        -ErrorAction SilentlyContinue
                if ($r -and $r.Value) {
                    foreach ($v in $r.Value.Values) { $lines += "$v" }
                }
            } catch {}
        }
        $output = ($lines -join "`n")
    } catch { return $overall }

    if ([string]::IsNullOrWhiteSpace($output)) {
        # No output yet - fall back to job status only.
        return $overall
    }

    $currentSku = $null  # current SKU header we're inside

    foreach ($ln in ($output -split "`r?`n")) {
        # New SKU section header:  ----- SKU X in <region> (target=N, group=...) -----
        if ($ln -match '-{3,}\s*SKU\s+(?<sku>\S+)\s+in\s+(?<region>\S+)') {
            $currentSku = [pscustomobject]@{
                Sku          = $Matches['sku']
                Region       = $Matches['region']
                Attempts     = 0
                Successes    = 0
                Failures     = 0
                LastCapacity = $null
                LastError    = ''
                Verdict      = ''
                VerdictCls   = 'idle'
            }
            $overall.Skus += $currentSku
            continue
        }

        if ($null -eq $currentSku) { continue }

        if ($ln -match 'CREATE\s+\d+' -or $ln -match 'GROW\s+\+\d+') {
            $currentSku.Attempts++
            $overall.Attempts++
        }
        if ($ln -match 'OK\.\s*capacity=(\d+)') {
            $currentSku.Successes++
            $currentSku.LastCapacity = [int]$Matches[1]
            $overall.Successes++
        }
        if ($ln -match '^\s*FAIL:') {
            $currentSku.Failures++
            $currentSku.LastError = ($ln -replace '^\s*FAIL:\s*','').Trim()
            $overall.Failures++
        }
        if ($ln -match 'Target already reached') {
            $currentSku.Verdict = 'Already reserved'
            $currentSku.VerdictCls = 'idle'
        } elseif ($ln -match 'Reservation restored to healthy state') {
            $currentSku.Verdict = 'Restored to healthy state'
            $currentSku.VerdictCls = 'work'
        } elseif ($ln -match 'Target reached') {
            $currentSku.Verdict = 'Target reached'
            $currentSku.VerdictCls = 'ok'
        }
        if ($ln -match 'Whole degrade sequence failed') {
            $currentSku.Verdict = 'No capacity available'
            $currentSku.VerdictCls = 'bad'
        }
    }

    # Fill any SKU that didn't get an explicit verdict.
    foreach ($s in $overall.Skus) {
        if ($s.Verdict) { continue }
        if ($s.Successes -gt 0) { $s.Verdict = "Reserved $($s.Successes) chunk(s)"; $s.VerdictCls = 'ok' }
        elseif ($s.Failures -gt 0) { $s.Verdict = 'Failed';   $s.VerdictCls = 'bad' }
        else { $s.Verdict = 'No action needed'; $s.VerdictCls = 'idle' }
    }

    # Overall verdict = worst-case across SKUs (if any bad -> bad, else if any work -> work, else ok)
    if ($overall.Skus.Count -eq 0) {
        switch ("$($job.Status)") {
            'Running'   { $overall.Verdict = 'Running...';           $overall.VerdictCls = 'work' }
            'Queued'    { $overall.Verdict = 'Queued';               $overall.VerdictCls = 'work' }
            'Activating'{ $overall.Verdict = 'Starting...';          $overall.VerdictCls = 'work' }
            'Starting'  { $overall.Verdict = 'Starting...';          $overall.VerdictCls = 'work' }
            'Failed'    { $overall.Verdict = 'Failed';               $overall.VerdictCls = 'bad' }
            'Suspended' { $overall.Verdict = 'Suspended';            $overall.VerdictCls = 'bad' }
            'Stopped'   { $overall.Verdict = 'Stopped';              $overall.VerdictCls = 'bad' }
            default     { $overall.Verdict = "$($job.Status)";       $overall.VerdictCls = 'idle' }
        }
    } elseif ($overall.Skus | Where-Object VerdictCls -eq 'bad') {
        $overall.Verdict = 'Some SKUs failed'; $overall.VerdictCls = 'bad'
    } elseif ($overall.Skus | Where-Object VerdictCls -eq 'ok') {
        $overall.Verdict = 'Reserved capacity'; $overall.VerdictCls = 'ok'
    } else {
        $overall.Verdict = 'Nothing to do'; $overall.VerdictCls = 'idle'
    }
    return $overall
}

# ---- Build HTML ----
$now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss UTC')

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine('<!doctype html>')
[void]$sb.AppendLine("<html lang='en'><head><meta charset='utf-8'/><title>Capacity Reservation Dashboard</title>")
[void]$sb.AppendLine("<meta http-equiv='refresh' content='60'/>")
[void]$sb.AppendLine("<meta name='viewport' content='width=device-width,initial-scale=1'/>")
[void]$sb.AppendLine(@'
<style>
:root {
  --bg:#0f172a; --panel:#1e293b; --panel2:#0b1220; --border:#334155;
  --text:#e2e8f0; --muted:#94a3b8; --brand:#38bdf8;
  --ok:#22c55e; --ok-bg:rgba(34,197,94,.12);
  --bad:#ef4444; --bad-bg:rgba(239,68,68,.14);
  --work:#f59e0b; --work-bg:rgba(245,158,11,.14);
  --idle:#64748b; --idle-bg:rgba(100,116,139,.14);
}
@media (prefers-color-scheme: light) {
  :root {
    --bg:#f8fafc; --panel:#ffffff; --panel2:#f1f5f9; --border:#e2e8f0;
    --text:#0f172a; --muted:#475569; --brand:#0284c7;
    --ok-bg:rgba(34,197,94,.10); --bad-bg:rgba(239,68,68,.10);
    --work-bg:rgba(245,158,11,.12); --idle-bg:rgba(100,116,139,.10);
  }
}
* { box-sizing: border-box; }
html,body { margin:0; padding:0; background:var(--bg); color:var(--text);
  font-family: -apple-system, "Segoe UI", Roboto, Oxygen, Ubuntu, Cantarell, sans-serif;
  font-size:14px; line-height:1.5; }
.wrap { max-width: 1100px; margin: 0 auto; padding: 28px 24px; }
header { display:flex; justify-content:space-between; align-items:flex-end; gap:16px;
  border-bottom:1px solid var(--border); padding-bottom:14px; margin-bottom:20px; flex-wrap:wrap; }
header h1 { margin:0; font-size:22px; letter-spacing:-.01em; }
header .sub { color:var(--muted); font-size:12px; margin-top:4px; }
header .badge { background:var(--panel); border:1px solid var(--border);
  padding:6px 12px; border-radius:999px; color:var(--muted); font-size:12px; }
.meta { color:var(--muted); font-size:12px; margin-bottom:20px; }
.meta b { color:var(--text); font-weight:600; }

.grid { display:grid; grid-template-columns: repeat(auto-fit, minmax(320px,1fr)); gap:14px; margin-bottom:24px; }
.card { background:var(--panel); border:1px solid var(--border); border-radius:12px;
  padding:18px 20px; box-shadow:0 1px 2px rgba(0,0,0,.04); }
.card h2 { margin:0 0 4px; font-size:15px;
  font-family: ui-monospace, "SF Mono", Consolas, monospace; word-break: break-all; }
.card .row { display:flex; justify-content:space-between; align-items:center; margin-top:14px; gap:10px; }
.card .num { font-size:26px; font-weight:600; letter-spacing:-.02em; }
.card .num small { font-size:14px; color:var(--muted); font-weight:500; margin-left:4px; }
.pill { display:inline-flex; align-items:center; gap:6px; padding:4px 10px; border-radius:999px;
  font-size:11px; font-weight:600; text-transform:uppercase; letter-spacing:.04em; white-space:nowrap; }
.pill.ok   { color:var(--ok);   background:var(--ok-bg); }
.pill.bad  { color:var(--bad);  background:var(--bad-bg); }
.pill.work { color:var(--work); background:var(--work-bg); }
.pill.idle { color:var(--idle); background:var(--idle-bg); }
.pill::before { content:''; width:6px; height:6px; border-radius:50%; background:currentColor; }

.progress { background:var(--panel2); border-radius:8px; height:8px; overflow:hidden; margin-top:12px; }
.progress > div { height:100%; background: linear-gradient(90deg, var(--brand), var(--ok));
  transition: width .3s ease; }

.section { background:var(--panel); border:1px solid var(--border); border-radius:12px; padding:8px 8px 4px; }
.section h3 { margin:14px 12px 8px; font-size:13px; text-transform:uppercase;
  letter-spacing:.06em; color:var(--muted); }
table { width:100%; border-collapse:collapse; }
th,td { padding:10px 12px; text-align:left; vertical-align:top; font-size:13px; border-bottom:1px solid var(--border); }
th { color:var(--muted); font-size:11px; text-transform:uppercase; letter-spacing:.05em; font-weight:600; }
tbody tr:last-child td { border-bottom:0; }
tbody tr:hover td { background: var(--panel2); }
td.mono { font-family: ui-monospace, "SF Mono", Consolas, monospace; font-size:12px; color:var(--muted); }
td.n   { text-align:right; font-variant-numeric: tabular-nums; }
.footer { color:var(--muted); font-size:11px; margin-top:24px; text-align:center; }
</style>
'@)
[void]$sb.AppendLine('</head><body><div class="wrap">')

# ---- Header ----
[void]$sb.AppendLine('<header>')
[void]$sb.AppendLine('<div><h1>Capacity Reservation Dashboard</h1>')
[void]$sb.AppendLine("<div class='sub'>Rendered $now &middot; auto-refresh every 60s</div></div>")
[void]$sb.AppendLine("<span class='badge'>$($rows.Count) SKU$(if ($rows.Count -eq 1) { '' } else { 's' }) &middot; $(($rows.Region | Select-Object -Unique).Count) region$(if ((($rows.Region | Select-Object -Unique).Count) -eq 1) { '' } else { 's' })</span>")
[void]$sb.AppendLine('</header>')

[void]$sb.AppendLine("<div class='meta'>Resource group <b>$(HtmlEnc $rgName)</b> &middot; Automation account <b>$(HtmlEnc $aaName)</b></div>")

# ---- SKU cards ----
if ($rows.Count -eq 0) {
    [void]$sb.AppendLine("<div class='section' style='padding:20px'>No targets configured. Set the <code>CR-Targets</code> Automation Variable.</div>")
} else {
    [void]$sb.AppendLine('<div class="grid">')
    foreach ($r in $rows) {
        [void]$sb.AppendLine('<div class="card">')
        [void]$sb.AppendLine("<h2>$(HtmlEnc $r.Sku)</h2>")
        [void]$sb.AppendLine("<div style='color:var(--muted);font-size:12px'>Region <b style='color:var(--text)'>$(HtmlEnc $r.Region)</b> &middot; Target <b style='color:var(--text)'>$($r.Target)</b> instances</div>")
        [void]$sb.AppendLine("<div class='row'><div class='num'>$($r.Confirmed)<small>/ $($r.Target)</small></div><span class='pill $($r.StatusCls)'>$(HtmlEnc $r.Status)</span></div>")
        [void]$sb.AppendLine("<div class='progress'><div style='width:$($r.Percent)%'></div></div>")
        [void]$sb.AppendLine("<div style='color:var(--muted);font-size:12px;margin-top:6px'>$($r.Percent)% reserved &middot; $($r.Remaining) still needed &middot; group <code>$(HtmlEnc $r.Group)</code></div>")
        [void]$sb.AppendLine('</div>')
    }
    [void]$sb.AppendLine('</div>')
}

# ---- Job history ----
# Each job may cover multiple SKUs. We render one row PER SKU per job, plus a
# 'summary' first row per job containing the started time + overall verdict.
[void]$sb.AppendLine('<div class="section">')
[void]$sb.AppendLine('<h3>Recent runbook jobs (top 15)</h3>')
[void]$sb.AppendLine('<table>')
[void]$sb.AppendLine('<thead><tr><th>Started (UTC)</th><th>Duration</th><th>SKU</th><th>Region</th><th>Outcome</th><th class="n">Attempts</th><th class="n">Reserved</th><th class="n">Failed</th><th>Details</th></tr></thead>')
[void]$sb.AppendLine('<tbody>')

if ($jobs.Count -gt 0) {
    foreach ($j in $jobs) {
        $summary = Get-JobSummary $j
        $start = if ($j.StartTime) { $j.StartTime.ToUniversalTime().ToString('MMM dd HH:mm:ss') } else { '—' }
        $dur = if ($j.StartTime -and $j.EndTime) {
                    $s = ($j.EndTime - $j.StartTime).TotalSeconds
                    if ($s -lt 60) { "$([int]$s)s" } else { "{0:F1}m" -f ($s/60) }
               } else { '—' }

        if ($summary.Skus.Count -eq 0) {
            # No SKU sections parsed (job crashed early or is still starting).
            [void]$sb.AppendLine("<tr><td>$start</td><td>$dur</td><td class='mono' style='color:var(--muted)'>—</td><td class='mono' style='color:var(--muted)'>—</td><td><span class='pill $($summary.VerdictCls)'>$(HtmlEnc $summary.Verdict)</span></td><td class='n'>0</td><td class='n'>0</td><td class='n'>0</td><td class='mono'></td></tr>")
        } else {
            $first = $true
            foreach ($s in $summary.Skus) {
                $detail = if ($null -ne $s.LastCapacity) { "capacity now = $($s.LastCapacity)" }
                          elseif ($s.LastError) { HtmlEnc ($s.LastError.Substring(0,[Math]::Min(80,$s.LastError.Length))) }
                          else { '' }
                # First row of the job carries the timestamp + duration; subsequent
                # rows leave those blank so the grouping is visually obvious.
                $st = if ($first) { $start } else { '' }
                $du = if ($first) { $dur }   else { '' }
                $first = $false
                [void]$sb.AppendLine("<tr><td>$st</td><td>$du</td><td class='mono'>$(HtmlEnc $s.Sku)</td><td>$(HtmlEnc $s.Region)</td><td><span class='pill $($s.VerdictCls)'>$(HtmlEnc $s.Verdict)</span></td><td class='n'>$($s.Attempts)</td><td class='n'>$($s.Successes)</td><td class='n'>$($s.Failures)</td><td class='mono'>$detail</td></tr>")
            }
        }
    }
} else {
    [void]$sb.AppendLine("<tr><td colspan='9' style='color:var(--muted);text-align:center;padding:20px'>No runbook jobs found yet. The scheduled run will fire at the top of the next hour.</td></tr>")
}
[void]$sb.AppendLine('</tbody></table></div>')

[void]$sb.AppendLine("<div class='footer'>Live from Azure &middot; capacity from reservation objects, jobs from Automation Account &middot; no database or storage used</div>")
[void]$sb.AppendLine('</div></body></html>')

# Atomically replace the file so nginx never reads a half-written page.
$tmp = "$outputPath.tmp"
Set-Content -Path $tmp -Value $sb.ToString() -Encoding UTF8 -NoNewline
Move-Item -Force -Path $tmp -Destination $outputPath
Write-Output "Dashboard rendered to $outputPath at $now"
