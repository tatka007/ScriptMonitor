#Requires -Version 5.1
<#
.SYNOPSIS
    Sdileny modul pro monitoring PowerShell skriptu pres Windows Event Log.
.DESCRIPTION
    Poskytuje funkce Start-ScriptMonitor a Stop-ScriptMonitor.
    Skripty importuji tento modul a volaji Start na zacatku, Stop na konci.
    Vysledky se zapisuji do Windows Event Log (Application, Source: ScriptMonitor).
.NOTES
    Verze: 1.0 (2026-04-15)
    Autor: Petr Pavlas
#>

Set-StrictMode -Version 2.0

# Interni stav modulu — slovnik aktivnich behu (klic = ScriptName)
$script:ActiveRuns = @{}

# Cesta k fallback logu pokud Event Log neni dostupny
$script:FallbackLogPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'fallback.log'

function Write-MonitorEvent {
    <#
    .SYNOPSIS
        Interni helper — zapise event do Event Logu nebo fallback souboru.
    #>
    param(
        [Parameter(Mandatory)][int]$EventId,
        [Parameter(Mandatory)][string]$Message,
        [System.Diagnostics.EventLogEntryType]$EntryType = 'Information'
    )

    $sourceName = 'ScriptMonitor'

    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists($sourceName)) {
            throw "Event Source '$sourceName' neni registrovan. Spustte Install-ScriptMonitor.ps1."
        }
        Write-EventLog -LogName 'Application' -Source $sourceName `
            -EventId $EventId -EntryType $EntryType -Message $Message
    }
    catch {
        # Fallback — zapis do souboru
        $fallbackDir = Split-Path -Parent $script:FallbackLogPath
        if ($fallbackDir -and -not (Test-Path $fallbackDir)) {
            New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        "[$timestamp] EventId=$EventId EntryType=$EntryType FALLBACK (EventLog nedostupny: $($_.Exception.Message))" |
            Out-File $script:FallbackLogPath -Append
        "$Message" | Out-File $script:FallbackLogPath -Append
        '---' | Out-File $script:FallbackLogPath -Append
    }
}

function Start-ScriptMonitor {
    <#
    .SYNOPSIS
        Zaznamenava spusteni skriptu (EventID 1003) a spousti mereni doby behu.
    .PARAMETER ScriptName
        Nazev skriptu (musi odpovidat Name v scripts-registry.json).
    .PARAMETER Version
        Verze skriptu (pro audit trail).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$Version = '0.0'
    )

    $run = @{
        ScriptName = $ScriptName
        Version    = $Version
        StartTime  = Get-Date
        Server     = $env:COMPUTERNAME
    }
    $script:ActiveRuns[$ScriptName] = $run

    $message = @(
        "ScriptName: $ScriptName"
        "Version: $Version"
        "Action: STARTED"
        "Server: $($env:COMPUTERNAME)"
        "StartTime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    ) -join "`n"

    Write-MonitorEvent -EventId 1003 -Message $message -EntryType Information
}

function Stop-ScriptMonitor {
    <#
    .SYNOPSIS
        Zaznamenava ukonceni skriptu (EventID 1000/1001/1002) vcetne statistik.
    .PARAMETER ScriptName
        Nazev skriptu. Pokud neuvedeno, pouzije posledni spusteny.
    .PARAMETER ExitCode
        Exit kod skriptu (0 = uspech).
    .PARAMETER ErrorCount
        Pocet chyb behem behu (pro rozliseni WARNING vs SUCCESS).
    .PARAMETER ItemsProcessed
        Pocet zpracovanych polozek (volitelne).
    .PARAMETER Details
        Textovy popis vysledku.
    #>
    [CmdletBinding()]
    param(
        [string]$ScriptName,
        [int]$ExitCode = 0,
        [int]$ErrorCount = 0,
        [int]$ItemsProcessed = 0,
        [string]$Details = ''
    )

    # Pokud neni ScriptName, pouzij posledni aktivni
    if (-not $ScriptName -and $script:ActiveRuns.Count -gt 0) {
        $ScriptName = ($script:ActiveRuns.Keys | Select-Object -Last 1)
    }

    # Vypocitej dobu behu
    $duration = [TimeSpan]::Zero
    $version = '0.0'
    $server = $env:COMPUTERNAME
    if ($ScriptName -and $script:ActiveRuns.ContainsKey($ScriptName)) {
        $run = $script:ActiveRuns[$ScriptName]
        $duration = (Get-Date) - $run.StartTime
        $version = $run.Version
        $server = $run.Server
        $script:ActiveRuns.Remove($ScriptName)
    }

    # Zvol EventID dle logiky:
    #   ExitCode = 0 a ErrorCount = 0 → 1000 (SUCCESS)
    #   ExitCode = 0 a ErrorCount > 0 → 1001 (WARNING)
    #   ExitCode != 0                 → 1002 (ERROR)
    if ($ExitCode -ne 0) {
        $eventId = 1002
        $entryType = [System.Diagnostics.EventLogEntryType]::Error
    }
    elseif ($ErrorCount -gt 0) {
        $eventId = 1001
        $entryType = [System.Diagnostics.EventLogEntryType]::Warning
    }
    else {
        $eventId = 1000
        $entryType = [System.Diagnostics.EventLogEntryType]::Information
    }

    $durationFormatted = '{0:hh\:mm\:ss}' -f $duration

    $message = @(
        "ScriptName: $ScriptName"
        "Version: $version"
        "Duration: $durationFormatted"
        "ExitCode: $ExitCode"
        "ItemsProcessed: $ItemsProcessed"
        "ErrorCount: $ErrorCount"
        "Details: $Details"
        "Server: $server"
    ) -join "`n"

    Write-MonitorEvent -EventId $eventId -Message $message -EntryType $entryType
}

Export-ModuleMember -Function Start-ScriptMonitor, Stop-ScriptMonitor
