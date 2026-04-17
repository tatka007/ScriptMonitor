#Requires -Version 5.1
<#
.SYNOPSIS
    Sdileny modul pro monitoring PowerShell skriptu pres Windows Event Log.
.DESCRIPTION
    Poskytuje funkce Start-ScriptMonitor a Stop-ScriptMonitor.
    Skripty importuji tento modul a volaji Start na zacatku, Stop na konci.
    Vysledky se zapisuji do Windows Event Log (Application, Source: ScriptMonitor).
.NOTES
    Verze: 1.1 (2026-04-17)
    Autor: Petr Pavlas
#>

Set-StrictMode -Version 2.0

# Interni stav modulu — ordered slovnik aktivnich behu (klic = ScriptName).
# Ordered dictionary garantuje insertion order pro "posledni aktivni" fallback.
$script:ActiveRuns = [ordered]@{}

# Cesta k fallback logu pokud Event Log neni dostupny
$script:FallbackLogPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition) 'fallback.log'

$script:MonitorSourceName = 'ScriptMonitor'

function Test-MonitorEventSource {
    <#
    .SYNOPSIS
        Wrapper nad [System.Diagnostics.EventLog]::SourceExists, ktery lze mockovat v testech.
    #>
    [CmdletBinding()]
    param()
    return [System.Diagnostics.EventLog]::SourceExists($script:MonitorSourceName)
}

function Format-MonitorFieldValue {
    <#
    .SYNOPSIS
        Sanitizuje hodnotu pole — odstrani CR/LF aby se nerozbily key:value radky v Event Log zprave.
    #>
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -replace "[`r`n]+", ' ').Trim()
}

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

    try {
        if (-not (Test-MonitorEventSource)) {
            throw "Event Source '$script:MonitorSourceName' neni registrovan. Spustte Install-ScriptMonitor.ps1."
        }
        Write-EventLog -LogName 'Application' -Source $script:MonitorSourceName `
            -EventId $EventId -EntryType $EntryType -Message $Message
    }
    catch {
        # Fallback — zapis do souboru jednim volanim (atomicky vzhledem ke kolegum).
        $fallbackDir = Split-Path -Parent $script:FallbackLogPath
        if ($fallbackDir -and -not (Test-Path $fallbackDir)) {
            New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
        }
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $block = @(
            "[$timestamp] EventId=$EventId EntryType=$EntryType FALLBACK (EventLog nedostupny: $($_.Exception.Message))"
            $Message
            '---'
            ''
        ) -join [Environment]::NewLine

        # FileShare.ReadWrite + Append → odolne vuci soubeznym zapisum z jinych procesu.
        try {
            $stream = [System.IO.File]::Open(
                $script:FallbackLogPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite
            )
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($block)
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $stream.Dispose()
            }
        }
        catch {
            # Posledni rezerva — pokud i fallback selze, nechceme padnout skript.
            Write-Warning "ScriptMonitor fallback log selhal: $($_.Exception.Message)"
        }
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

    $safeName    = Format-MonitorFieldValue $ScriptName
    $safeVersion = Format-MonitorFieldValue $Version

    $run = @{
        ScriptName = $safeName
        Version    = $safeVersion
        StartTime  = Get-Date
        Server     = $env:COMPUTERNAME
    }
    # Pokud uz existuje, nahradime (restart skriptu bez Stop volani).
    if ($script:ActiveRuns.Contains($safeName)) {
        $script:ActiveRuns.Remove($safeName)
    }
    $script:ActiveRuns[$safeName] = $run

    $message = @(
        "ScriptName: $safeName"
        "Version: $safeVersion"
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
        Nazev skriptu. Pokud neuvedeno, pouzije posledni spusteny (insertion order).
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

    # Pokud neni ScriptName, pouzij posledni aktivni (ordered dict — insertion order).
    if (-not $ScriptName -and $script:ActiveRuns.Count -gt 0) {
        # Hledej zaznam s nejnovejsim StartTime (odolnejsi nez spolehat se na klicove poradi).
        $latest = $null
        foreach ($entry in $script:ActiveRuns.GetEnumerator()) {
            if (-not $latest -or $entry.Value.StartTime -gt $latest.Value.StartTime) {
                $latest = $entry
            }
        }
        if ($latest) { $ScriptName = $latest.Key }
    }

    $ScriptName = Format-MonitorFieldValue $ScriptName

    # Vypocitej dobu behu
    $duration = [TimeSpan]::Zero
    $version = '0.0'
    $server = $env:COMPUTERNAME
    if ($ScriptName -and $script:ActiveRuns.Contains($ScriptName)) {
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

    # Format "d.hh:mm:ss" aby se nesplyla >24h trvani (jinak by se hodiny orezaly modulo 24).
    if ($duration.TotalDays -ge 1) {
        $durationFormatted = '{0:d\.hh\:mm\:ss}' -f $duration
    } else {
        $durationFormatted = '{0:hh\:mm\:ss}' -f $duration
    }

    $safeDetails = Format-MonitorFieldValue $Details

    $message = @(
        "ScriptName: $ScriptName"
        "Version: $version"
        "Duration: $durationFormatted"
        "ExitCode: $ExitCode"
        "ItemsProcessed: $ItemsProcessed"
        "ErrorCount: $ErrorCount"
        "Details: $safeDetails"
        "Server: $server"
    ) -join "`n"

    Write-MonitorEvent -EventId $eventId -Message $message -EntryType $entryType
}

Export-ModuleMember -Function Start-ScriptMonitor, Stop-ScriptMonitor, Test-MonitorEventSource
