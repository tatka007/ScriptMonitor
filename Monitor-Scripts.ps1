#Requires -Version 5.1
<#
.SYNOPSIS
    Monitorovaci skript — cte Event Log, vyhodnocuje status skriptu, generuje HTML dashboard.
.DESCRIPTION
    Nacte registr skriptu z scripts-registry.json, dotahne posledni eventy
    ze Source "ScriptMonitor" v Application logu, porovna se schedule
    a vygeneruje statickou HTML stranku s prehledem.
.PARAMETER RegistryPath
    Cesta ke scripts-registry.json (vychozi: ve stejnem adresari).
.PARAMETER OutputPath
    Cesta k vystupnimu HTML souboru (vychozi: dashboard.html ve stejnem adresari).
.PARAMETER LookbackHours
    Jak daleko zpet v Event Logu hledat (vychozi: 48 hodin).
.NOTES
    Verze: 1.0 (2026-04-15)
    Autor: Petr Pavlas
    Schedule: Task Scheduler, kazdych 30 minut
#>

[CmdletBinding()]
param(
    [string]$RegistryPath,
    [string]$OutputPath,
    [int]$LookbackHours = 48
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if (-not $RegistryPath) { $RegistryPath = Join-Path $ScriptDir 'scripts-registry.json' }
if (-not $OutputPath)   { $OutputPath = Join-Path $ScriptDir 'dashboard.html' }

# Nacteni registru
$registry = Get-Content $RegistryPath -Raw | ConvertFrom-Json

# Parsovani Event Log zpravy do hashtable
function ConvertFrom-MonitorMessage {
    param([Parameter(Mandatory)][string]$RawMessage)

    $result = @{}
    foreach ($line in $RawMessage -split "`n") {
        $line = $line.Trim()
        if ($line -match '^(\w+):\s*(.*)$') {
            $result[$Matches[1]] = $Matches[2]
        }
    }
    return $result
}

# Stazeni eventu ze serveru (lokalni nebo remote)
function Get-MonitorEvents {
    param(
        [string]$ServerName = 'localhost',
        [int]$Hours = 48
    )

    $filterHash = @{
        LogName      = 'Application'
        ProviderName = 'ScriptMonitor'
        StartTime    = (Get-Date).AddHours(-$Hours)
    }

    $params = @{
        FilterHashtable = $filterHash
        MaxEvents       = 500
        ErrorAction     = 'SilentlyContinue'
    }
    if ($ServerName -ne 'localhost' -and $ServerName -ne $env:COMPUTERNAME) {
        $params['ComputerName'] = $ServerName
    }

    $events = Get-WinEvent @params
    if (-not $events) { return @() }

    return $events | ForEach-Object {
        $parsed = ConvertFrom-MonitorMessage -RawMessage $_.Message
        [PSCustomObject]@{
            EventId    = $_.Id
            TimeCreated = $_.TimeCreated
            EntryType  = $_.LevelDisplayName
            ScriptName = $parsed['ScriptName']
            Version    = $parsed['Version']
            Duration   = $parsed['Duration']
            ExitCode   = $parsed['ExitCode']
            ItemsProcessed = $parsed['ItemsProcessed']
            ErrorCount = $parsed['ErrorCount']
            Details    = $parsed['Details']
            Server     = $parsed['Server']
        }
    }
}

# Vyhodnoceni statusu jednoho skriptu na zaklade registru a eventu
function Get-ScriptStatus {
    param(
        [Parameter(Mandatory)]$RegistryEntry,
        [array]$Events
    )

    # Filtrace eventu pro tento skript
    $scriptEvents = $Events | Where-Object { $_.ScriptName -eq $RegistryEntry.Name } |
        Sort-Object TimeCreated -Descending

    # Zadne eventy = MISSING
    if (-not $scriptEvents -or $scriptEvents.Count -eq 0) {
        return [PSCustomObject]@{
            Name          = $RegistryEntry.Name
            Server        = $RegistryEntry.Server
            Status        = 'MISSING'
            LastRun       = $null
            Duration      = $null
            Details       = 'Zadny zaznam v Event Logu'
            ExitCode      = $null
            Critical      = [bool]$RegistryEntry.Critical
            RecentRuns    = @()
        }
    }

    # Posledni STOP event (1000, 1001, 1002)
    $lastStop = $scriptEvents | Where-Object { $_.EventId -in @(1000, 1001, 1002) } | Select-Object -First 1

    # Posledni START event (1003)
    $lastStart = $scriptEvents | Where-Object { $_.EventId -eq 1003 } | Select-Object -First 1

    # Detekce RUNNING — ma START ale zadny novejsi STOP
    if ($lastStart -and (-not $lastStop -or $lastStart.TimeCreated -gt $lastStop.TimeCreated)) {
        $runningMinutes = ((Get-Date) - $lastStart.TimeCreated).TotalMinutes
        $maxMin = if ($RegistryEntry.MaxDurationMin) { $RegistryEntry.MaxDurationMin } else { 60 }
        $status = if ($runningMinutes -gt $maxMin) { 'ERROR' } else { 'RUNNING' }

        return [PSCustomObject]@{
            Name          = $RegistryEntry.Name
            Server        = $RegistryEntry.Server
            Status        = $status
            LastRun       = $lastStart.TimeCreated
            Duration      = "{0:N0} min (bezi)" -f $runningMinutes
            Details       = if ($status -eq 'ERROR') { "Bezi prilis dlouho ($([math]::Round($runningMinutes)) min, limit $maxMin min)" } else { 'Probiha...' }
            ExitCode      = $null
            Critical      = [bool]$RegistryEntry.Critical
            RecentRuns    = @()
        }
    }

    # Status dle posledniho STOP eventu
    $status = switch ($lastStop.EventId) {
        1000 { 'OK' }
        1001 { 'WARNING' }
        1002 { 'ERROR' }
    }

    # Kontrola jestli beh probehl v ocekavanem intervalu
    if ($status -eq 'OK') {
        $hoursSinceRun = ((Get-Date) - $lastStop.TimeCreated).TotalHours
        $maxHours = switch ($RegistryEntry.Schedule) {
            'daily'   { 36 }
            'weekly'  { 192 }
            'monthly' { 792 }
            default   { 48 }
        }
        if ($hoursSinceRun -gt $maxHours) {
            $status = 'MISSING'
        }
    }

    # Poslednich 5 STOP behu pro detail
    $recentRuns = $scriptEvents |
        Where-Object { $_.EventId -in @(1000, 1001, 1002) } |
        Select-Object -First 5 |
        ForEach-Object {
            [PSCustomObject]@{
                Time     = $_.TimeCreated
                EventId  = $_.EventId
                Duration = $_.Duration
                Items    = $_.ItemsProcessed
                Details  = $_.Details
            }
        }

    return [PSCustomObject]@{
        Name          = $RegistryEntry.Name
        Server        = $RegistryEntry.Server
        Status        = $status
        LastRun       = $lastStop.TimeCreated
        Duration      = $lastStop.Duration
        Details       = $lastStop.Details
        ExitCode      = $lastStop.ExitCode
        Critical      = [bool]$RegistryEntry.Critical
        RecentRuns    = $recentRuns
    }
}

# Generovani HTML dashboardu
function ConvertTo-DashboardHtml {
    param(
        [Parameter(Mandatory)][array]$Statuses
    )

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    $countOk      = ($Statuses | Where-Object Status -eq 'OK').Count
    $countWarning = ($Statuses | Where-Object Status -eq 'WARNING').Count
    $countError   = ($Statuses | Where-Object Status -eq 'ERROR').Count
    $countMissing = ($Statuses | Where-Object Status -eq 'MISSING').Count
    $countRunning = ($Statuses | Where-Object Status -eq 'RUNNING').Count

    $statusColor = @{
        'OK'      = '#22c55e'
        'WARNING' = '#eab308'
        'ERROR'   = '#ef4444'
        'MISSING' = '#9ca3af'
        'RUNNING' = '#3b82f6'
    }

    $tableRows = foreach ($s in $Statuses) {
        $color = $statusColor[$s.Status]
        $lastRunText = if ($s.LastRun) { $s.LastRun.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        $durationText = if ($s.Duration) { $s.Duration } else { '-' }
        $criticalBadge = if ($s.Critical) { ' <span class="badge-crit">CRITICAL</span>' } else { '' }
        $detailsText = if ($s.Details) { $s.Details } else { '' }
        $detailsEncoded = [System.Net.WebUtility]::HtmlEncode($detailsText)
        $detailsShort = if ($detailsText.Length -gt 40) { [System.Net.WebUtility]::HtmlEncode($detailsText.Substring(0,40)) + '...' } else { $detailsEncoded }

        $detailRows = ''
        if ($s.RecentRuns -and $s.RecentRuns.Count -gt 0) {
            $detailRows = ($s.RecentRuns | ForEach-Object {
                $statusIcon = switch ($_.EventId) {
                    1000 { '<span style="color:#22c55e">OK</span>' }
                    1001 { '<span style="color:#eab308">WARN</span>' }
                    1002 { '<span style="color:#ef4444">ERR</span>' }
                }
                $runTime = $_.Time.ToString('yyyy-MM-dd HH:mm')
                $dur = if ($_.Duration) { $_.Duration } else { '-' }
                $items = if ($_.Items) { $_.Items } else { '-' }
                $det = if ($_.Details) { [System.Net.WebUtility]::HtmlEncode($_.Details) } else { '-' }
                "<tr><td>$runTime</td><td>$statusIcon</td><td>$dur</td><td>$items</td><td>$det</td></tr>"
            }) -join "`n"
        }

        $detailId = "detail-$($s.Name -replace '\s','_')"

        @"
<tr class="main-row" onclick="toggleDetail('$detailId')">
    <td><strong>$($s.Name)</strong>$criticalBadge</td>
    <td>$($s.Server)</td>
    <td><span class="status" style="background:$color">$($s.Status)</span></td>
    <td>$lastRunText</td>
    <td>$durationText</td>
    <td title="$detailsEncoded">$detailsShort</td>
</tr>
<tr id="$detailId" class="detail-row" style="display:none">
    <td colspan="6">
        <table class="detail-table">
            <tr><th>Cas</th><th>Status</th><th>Doba</th><th>Polozky</th><th>Detail</th></tr>
            $detailRows
        </table>
    </td>
</tr>
"@
    }

    $tableRowsHtml = $tableRows -join "`n"

    return @"
<!DOCTYPE html>
<html lang="cs">
<head>
    <meta charset="UTF-8">
    <meta http-equiv="refresh" content="300">
    <title>Script Monitor Dashboard</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #0f172a; color: #e2e8f0; padding: 20px; }
        h1 { font-size: 1.5rem; margin-bottom: 4px; }
        .header { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 16px; }
        .generated { color: #64748b; font-size: 0.85rem; }
        .summary { display: flex; gap: 16px; margin-bottom: 20px; flex-wrap: wrap; }
        .summary-item { padding: 8px 16px; border-radius: 8px; background: #1e293b; font-size: 0.95rem; }
        .summary-item .count { font-size: 1.3rem; font-weight: bold; margin-right: 6px; }
        table { width: 100%; border-collapse: collapse; }
        th { background: #1e293b; padding: 10px 12px; text-align: left; font-size: 0.85rem; text-transform: uppercase; color: #94a3b8; }
        td { padding: 10px 12px; border-bottom: 1px solid #1e293b; }
        .main-row { cursor: pointer; transition: background 0.15s; }
        .main-row:hover { background: #1e293b; }
        .status { padding: 3px 10px; border-radius: 12px; color: #fff; font-size: 0.8rem; font-weight: 600; }
        .badge-crit { background: #7c2d12; color: #fbbf24; padding: 1px 6px; border-radius: 4px; font-size: 0.7rem; margin-left: 6px; }
        .detail-table { width: 100%; margin: 8px 0; }
        .detail-table th { background: #0f172a; font-size: 0.75rem; padding: 4px 8px; }
        .detail-table td { padding: 4px 8px; font-size: 0.85rem; border-bottom: 1px solid #1e293b; }
        .detail-row td { background: #1a2332; padding: 0 12px; }
    </style>
    <script>
        function toggleDetail(id) {
            var el = document.getElementById(id);
            el.style.display = el.style.display === 'none' ? 'table-row' : 'none';
        }
    </script>
</head>
<body>
    <div class="header">
        <h1>Script Monitor Dashboard</h1>
        <span class="generated">Aktualizovano: $generated</span>
    </div>
    <div class="summary">
        <div class="summary-item"><span class="count" style="color:#22c55e">$countOk</span> OK</div>
        <div class="summary-item"><span class="count" style="color:#eab308">$countWarning</span> WARNING</div>
        <div class="summary-item"><span class="count" style="color:#ef4444">$countError</span> ERROR</div>
        <div class="summary-item"><span class="count" style="color:#9ca3af">$countMissing</span> MISSING</div>
        <div class="summary-item"><span class="count" style="color:#3b82f6">$countRunning</span> RUNNING</div>
    </div>
    <table>
        <tr>
            <th>Skript</th>
            <th>Server</th>
            <th>Status</th>
            <th>Posledni beh</th>
            <th>Doba behu</th>
            <th>Detail</th>
        </tr>
        $tableRowsHtml
    </table>
</body>
</html>
"@
}

# --- Hlavni logika ---

$servers = $registry | Select-Object -ExpandProperty Server -Unique
$allEvents = @()
foreach ($server in $servers) {
    $allEvents += Get-MonitorEvents -ServerName $server -Hours $LookbackHours
}

$statuses = foreach ($entry in $registry) {
    Get-ScriptStatus -RegistryEntry $entry -Events $allEvents
}

# --- Generovani HTML ---
$html = ConvertTo-DashboardHtml -Statuses $statuses

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$html | Out-File -FilePath $OutputPath -Encoding utf8 -Force
Write-Host "Dashboard vygenerovan: $OutputPath" -ForegroundColor Green
Write-Host "Skriptu: $($statuses.Count) | OK: $(($statuses | Where-Object Status -eq 'OK').Count) | ERROR: $(($statuses | Where-Object Status -eq 'ERROR').Count) | MISSING: $(($statuses | Where-Object Status -eq 'MISSING').Count)"
