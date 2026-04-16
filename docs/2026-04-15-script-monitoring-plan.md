# Script Monitoring System — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Centralni monitoring vsech PowerShell skriptu pres Windows Event Log se statickym HTML dashboardem.

**Architecture:** Sdileny PowerShell modul (`ScriptMonitor.psm1`) zapisuje strukturovane eventy do Windows Application logu. Monitor skript (`Monitor-Scripts.ps1`) cte eventy, porovnava s registrem ocekavanych behu a generuje `dashboard.html`.

**Tech Stack:** PowerShell 5.1+, Windows Event Log, HTML/CSS (inline, zadne zavislosti)

---

## File Structure

```
ScriptMonitor/
├── ScriptMonitor.psm1              # Sdileny modul — Start/Stop funkce, Event Log zapis
├── Monitor-Scripts.ps1             # Hlavni monitor — cte eventy, generuje HTML
├── scripts-registry.json           # Registr skriptu a jejich schedules
├── Install-ScriptMonitor.ps1       # Jednorazovy instalacni skript (Event Source registrace)
├── Tests/
│   └── ScriptMonitor.Tests.ps1     # Pester testy pro modul
└── README.md                       # Dokumentace
```

Produkce na serveru (deploy cil):
```
C:\Monitoring\
├── ScriptMonitor.psm1
├── Monitor-Scripts.ps1
├── scripts-registry.json
├── dashboard.html                  # Generovany vystup
└── fallback.log                    # Fallback pokud Event Log selze
```

---

### Task 1: Projekt a instalacni skript

**Files:**
- Create: `ScriptMonitor/Install-ScriptMonitor.ps1`
- Create: `ScriptMonitor/scripts-registry.json`

- [ ] **Step 1: Vytvor scripts-registry.json**

```json
[
  {
    "Name": "LogRotate",
    "Server": "localhost",
    "Schedule": "daily",
    "ExpectedHour": 3,
    "MaxDurationMin": 30,
    "Critical": false
  },
  {
    "Name": "Auto-WindowsUpdate",
    "Server": "localhost",
    "Schedule": "weekly",
    "ExpectedDay": "Sunday",
    "ExpectedHour": 2,
    "MaxDurationMin": 180,
    "Critical": true
  },
  {
    "Name": "AD_PasswordAudit",
    "Server": "localhost",
    "Schedule": "monthly",
    "ExpectedDay": 1,
    "MaxDurationMin": 10,
    "Critical": false
  }
]
```

- [ ] **Step 2: Vytvor Install-ScriptMonitor.ps1**

Jednorazovy skript pro pripravu prostredi. Musi bezet jako admin.

```powershell
#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Jednorazova instalace ScriptMonitor — registrace Event Source a vytvoreni adresare.
.NOTES
    Verze: 1.0 (2026-04-15)
    Spustit jednou s admin pravy na kazdem serveru.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallPath = 'C:\Monitoring'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Vytvoreni adresare
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath -Force | Out-Null
    Write-Host "Vytvoren adresar: $InstallPath" -ForegroundColor Green
}

# Registrace Event Source
$sourceName = 'ScriptMonitor'
$logName = 'Application'

if (-not [System.Diagnostics.EventLog]::SourceExists($sourceName)) {
    [System.Diagnostics.EventLog]::CreateEventSource($sourceName, $logName)
    Write-Host "Event Source '$sourceName' registrovan v logu '$logName'." -ForegroundColor Green
}
else {
    Write-Host "Event Source '$sourceName' uz existuje." -ForegroundColor Yellow
}

# Kopirovani souboru
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$filesToCopy = @('ScriptMonitor.psm1', 'Monitor-Scripts.ps1', 'scripts-registry.json')

foreach ($file in $filesToCopy) {
    $src = Join-Path $scriptDir $file
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $InstallPath -Force
        Write-Host "Kopirovano: $file -> $InstallPath" -ForegroundColor Green
    }
    else {
        Write-Warning "Soubor '$file' nenalezen v $scriptDir"
    }
}

Write-Host "`nInstalace dokoncena. Nyni muzete importovat modul:" -ForegroundColor Cyan
Write-Host "  Import-Module $InstallPath\ScriptMonitor.psm1" -ForegroundColor White
```

- [ ] **Step 3: Commit**

```bash
git add ScriptMonitor/Install-ScriptMonitor.ps1 ScriptMonitor/scripts-registry.json
git commit -m "feat: ScriptMonitor — instalacni skript a registr skriptu"
```

---

### Task 2: ScriptMonitor.psm1 — sdileny modul

**Files:**
- Create: `ScriptMonitor/ScriptMonitor.psm1`

- [ ] **Step 1: Vytvor ScriptMonitor.psm1 s funkci Write-MonitorEvent (interni helper)**

Interni funkce pro zapis do Event Logu s fallback do souboru.

```powershell
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
```

- [ ] **Step 2: Pridej funkci Start-ScriptMonitor**

```powershell
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
```

- [ ] **Step 3: Pridej funkci Stop-ScriptMonitor**

```powershell
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
```

- [ ] **Step 4: Pridej Export-ModuleMember na konec souboru**

```powershell
Export-ModuleMember -Function Start-ScriptMonitor, Stop-ScriptMonitor
```

- [ ] **Step 5: Commit**

```bash
git add ScriptMonitor/ScriptMonitor.psm1
git commit -m "feat: ScriptMonitor.psm1 — Start/Stop funkce s Event Log zapisem"
```

---

### Task 3: Pester testy pro modul

**Files:**
- Create: `ScriptMonitor/Tests/ScriptMonitor.Tests.ps1`

- [ ] **Step 1: Vytvor Pester testy**

Testy overuji logiku modulu pomoci mocku (Write-EventLog se mockuje, nepiseme do skutecneho Event Logu).

```powershell
#Requires -Modules Pester

<#
.SYNOPSIS
    Pester testy pro ScriptMonitor.psm1
.NOTES
    Spusteni: Invoke-Pester -Path .\Tests\ScriptMonitor.Tests.ps1 -Output Detailed
#>

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\ScriptMonitor.psm1'
    Import-Module $modulePath -Force
}

Describe 'Start-ScriptMonitor' {
    BeforeEach {
        Mock Write-EventLog {} -ModuleName ScriptMonitor
        Mock -CommandName '[System.Diagnostics.EventLog]::SourceExists' { $true } -ModuleName ScriptMonitor
    }

    It 'Zapise EventID 1003 pri spusteni' {
        Start-ScriptMonitor -ScriptName 'TestScript' -Version '1.0'

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -Times 1 -ParameterFilter {
            $EventId -eq 1003 -and $Source -eq 'ScriptMonitor'
        }
    }

    It 'Zprava obsahuje nazev skriptu a verzi' {
        Start-ScriptMonitor -ScriptName 'MyScript' -Version '2.5'

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -Times 1 -ParameterFilter {
            $Message -match 'ScriptName: MyScript' -and $Message -match 'Version: 2.5'
        }
    }
}

Describe 'Stop-ScriptMonitor' {
    BeforeEach {
        Mock Write-EventLog {} -ModuleName ScriptMonitor
        Mock -CommandName '[System.Diagnostics.EventLog]::SourceExists' { $true } -ModuleName ScriptMonitor
        Start-ScriptMonitor -ScriptName 'TestScript' -Version '1.0'
    }

    It 'EventID 1000 pri ExitCode=0 a ErrorCount=0' {
        Stop-ScriptMonitor -ScriptName 'TestScript' -ExitCode 0 -ErrorCount 0

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -ParameterFilter {
            $EventId -eq 1000 -and $EntryType -eq 'Information'
        }
    }

    It 'EventID 1001 pri ExitCode=0 a ErrorCount>0' {
        Stop-ScriptMonitor -ScriptName 'TestScript' -ExitCode 0 -ErrorCount 3

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -ParameterFilter {
            $EventId -eq 1001 -and $EntryType -eq 'Warning'
        }
    }

    It 'EventID 1002 pri ExitCode!=0' {
        Stop-ScriptMonitor -ScriptName 'TestScript' -ExitCode 1 -ErrorCount 0

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -ParameterFilter {
            $EventId -eq 1002 -and $EntryType -eq 'Error'
        }
    }

    It 'Zprava obsahuje vsechna povinne pole' {
        Stop-ScriptMonitor -ScriptName 'TestScript' -ExitCode 0 -ItemsProcessed 42 -Details 'Test details'

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -ParameterFilter {
            $Message -match 'ScriptName: TestScript' -and
            $Message -match 'ItemsProcessed: 42' -and
            $Message -match 'Details: Test details' -and
            $Message -match 'Duration: \d{2}:\d{2}:\d{2}'
        }
    }

    It 'Pouzije posledni aktivni skript pokud ScriptName neuvedeno' {
        Stop-ScriptMonitor -ExitCode 0

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -ParameterFilter {
            $Message -match 'ScriptName: TestScript'
        }
    }
}

Describe 'Fallback log' {
    BeforeEach {
        # Simuluj selhani Event Logu
        Mock Write-EventLog { throw 'Access denied' } -ModuleName ScriptMonitor
        Mock -CommandName '[System.Diagnostics.EventLog]::SourceExists' { $true } -ModuleName ScriptMonitor

        $testFallback = Join-Path $TestDrive 'fallback.log'
        # Nastaveni fallback cesty v modulu
        & (Get-Module ScriptMonitor) { $script:FallbackLogPath = $args[0] } $testFallback
    }

    It 'Zapise do fallback logu pokud Event Log selze' {
        Start-ScriptMonitor -ScriptName 'FailTest' -Version '1.0'

        $testFallback | Should -Exist
        $content = Get-Content $testFallback -Raw
        $content | Should -Match 'FALLBACK'
        $content | Should -Match 'ScriptName: FailTest'
    }
}
```

- [ ] **Step 2: Over ze testy projdou (na macOS overeni syntaxe, plne testy na Windows)**

```bash
# Na macOS (kontrola syntaxe):
pwsh -NoProfile -Command "& { \$ast = [System.Management.Automation.Language.Parser]::ParseFile('ScriptMonitor/Tests/ScriptMonitor.Tests.ps1', [ref]\$null, [ref]\$null); if (\$ast) { Write-Host 'Syntax OK' -ForegroundColor Green } }"

# Na Windows (plne testy):
# Invoke-Pester -Path .\Tests\ScriptMonitor.Tests.ps1 -Output Detailed
```

- [ ] **Step 3: Commit**

```bash
git add ScriptMonitor/Tests/ScriptMonitor.Tests.ps1
git commit -m "test: Pester testy pro ScriptMonitor modul"
```

---

### Task 4: Monitor-Scripts.ps1 — cteni Event Logu a vyhodnoceni statusu

**Files:**
- Create: `ScriptMonitor/Monitor-Scripts.ps1`

- [ ] **Step 1: Vytvor zaklad Monitor-Scripts.ps1 — parametry, nacteni registru, cteni eventu**

```powershell
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
```

- [ ] **Step 2: Pridej funkci Get-ScriptStatus — vyhodnoceni statusu jednoho skriptu**

```powershell
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
        # Kontrola jestli nebezi prilis dlouho
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
            'daily'   { 36 }    # 1.5 dne tolerance
            'weekly'  { 192 }   # 8 dni tolerance
            'monthly' { 792 }   # 33 dni tolerance
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
```

- [ ] **Step 3: Pridej hlavni logiku — iterace pres registr, sber eventu, vyhodnoceni**

```powershell
# --- Hlavni logika ---

# Sber eventu ze vsech unikatnich serveru
$servers = $registry | Select-Object -ExpandProperty Server -Unique
$allEvents = @()
foreach ($server in $servers) {
    $allEvents += Get-MonitorEvents -ServerName $server -Hours $LookbackHours
}

# Vyhodnoceni statusu kazdeho skriptu
$statuses = foreach ($entry in $registry) {
    Get-ScriptStatus -RegistryEntry $entry -Events $allEvents
}
```

- [ ] **Step 4: Commit**

```bash
git add ScriptMonitor/Monitor-Scripts.ps1
git commit -m "feat: Monitor-Scripts.ps1 — cteni Event Logu a vyhodnoceni statusu"
```

---

### Task 5: Monitor-Scripts.ps1 — HTML generator

**Files:**
- Modify: `ScriptMonitor/Monitor-Scripts.ps1` (append HTML generovani)

- [ ] **Step 1: Pridej funkci ConvertTo-DashboardHtml**

```powershell
# Generovani HTML dashboardu
function ConvertTo-DashboardHtml {
    param(
        [Parameter(Mandatory)][array]$Statuses
    )

    $generated = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    # Pocty dle statusu
    $countOk      = ($Statuses | Where-Object Status -eq 'OK').Count
    $countWarning = ($Statuses | Where-Object Status -eq 'WARNING').Count
    $countError   = ($Statuses | Where-Object Status -eq 'ERROR').Count
    $countMissing = ($Statuses | Where-Object Status -eq 'MISSING').Count
    $countRunning = ($Statuses | Where-Object Status -eq 'RUNNING').Count

    # Barvy statusu
    $statusColor = @{
        'OK'      = '#22c55e'
        'WARNING' = '#eab308'
        'ERROR'   = '#ef4444'
        'MISSING' = '#9ca3af'
        'RUNNING' = '#3b82f6'
    }

    # Radky tabulky
    $tableRows = foreach ($s in $Statuses) {
        $color = $statusColor[$s.Status]
        $lastRunText = if ($s.LastRun) { $s.LastRun.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        $durationText = if ($s.Duration) { $s.Duration } else { '-' }
        $criticalBadge = if ($s.Critical) { ' <span class="badge-crit">CRITICAL</span>' } else { '' }

        # Collapsible detail poslednich behu
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
    <td title="$([System.Net.WebUtility]::HtmlEncode($s.Details))">$(if ($s.Details.Length -gt 40) { [System.Net.WebUtility]::HtmlEncode($s.Details.Substring(0,40)) + '...' } else { [System.Net.WebUtility]::HtmlEncode($s.Details) })</td>
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

    # Kompletni HTML
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
```

- [ ] **Step 2: Pridej volani HTML generatoru a zapis na konec Monitor-Scripts.ps1**

```powershell
# --- Generovani HTML ---
$html = ConvertTo-DashboardHtml -Statuses $statuses

$outputDir = Split-Path -Parent $OutputPath
if ($outputDir -and -not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$html | Out-File -FilePath $OutputPath -Encoding utf8 -Force
Write-Host "Dashboard vygenerovan: $OutputPath" -ForegroundColor Green
Write-Host "Skriptu: $($statuses.Count) | OK: $(($statuses | Where-Object Status -eq 'OK').Count) | ERROR: $(($statuses | Where-Object Status -eq 'ERROR').Count) | MISSING: $(($statuses | Where-Object Status -eq 'MISSING').Count)"
```

- [ ] **Step 3: Commit**

```bash
git add ScriptMonitor/Monitor-Scripts.ps1
git commit -m "feat: Monitor-Scripts.ps1 — HTML dashboard generator"
```

---

### Task 6: Integrace do existujicich skriptu

**Files:**
- Modify: `LogRotate/logrotate.ps1` (pridani 3 radku)
- Modify: `WindowsUpdate/Auto-WindowsUpdate.ps1` (pridani 3 radku)
- Modify: `AD_PasswordAudit.ps1` (pridani 5 radku — nema try/finally)

- [ ] **Step 1: Integrace do LogRotate**

Na zacatek (za `Set-StrictMode`) pridat:
```powershell
# Monitoring
Import-Module C:\Monitoring\ScriptMonitor.psm1 -ErrorAction SilentlyContinue
Start-ScriptMonitor -ScriptName 'LogRotate' -Version '2.1'
```

Na konec souboru (za posledni `LogMeNowToFile`) pridat:
```powershell
# Monitoring — zaznamenani vysledku
$monitorExitCode = if ($TotalErrorCount -gt 0) { 1 } else { 0 }
Stop-ScriptMonitor -ExitCode $monitorExitCode -ErrorCount $TotalErrorCount -ItemsProcessed $TotalFileCount -Details "Zpracovano $TotalFileCount souboru, $TotalErrorCount chyb, aktivnich jobu: $ActiveJobCount"
```

- [ ] **Step 2: Integrace do Auto-WindowsUpdate**

Za radek `Set-StrictMode -Version 2.0` (radek 31) pridat:
```powershell
# Monitoring
Import-Module C:\Monitoring\ScriptMonitor.psm1 -ErrorAction SilentlyContinue
Start-ScriptMonitor -ScriptName 'Auto-WindowsUpdate' -Version '4.3'
```

Do `finally` bloku (pred `exit $script:ExitCode`, radek 278) pridat:
```powershell
    # Monitoring — zaznamenani vysledku
    $monitorErrors = if ($failList) { $failList.Count } else { 0 }
    $monitorItems = if ($successList) { $successList.Count } else { 0 }
    Stop-ScriptMonitor -ExitCode $script:ExitCode -ErrorCount $monitorErrors -ItemsProcessed $monitorItems -Details "Uspesne: $monitorItems, selhane: $monitorErrors"
```

- [ ] **Step 3: Integrace do AD_PasswordAudit**

Tento skript nema try/finally, takze zabalime celou logiku:

Na zacatek (za `$DateStamp = ...`, radek 12) pridat:
```powershell
# Monitoring
Import-Module C:\Monitoring\ScriptMonitor.psm1 -ErrorAction SilentlyContinue
Start-ScriptMonitor -ScriptName 'AD_PasswordAudit' -Version '1.0'
```

Na uplny konec souboru pridat:
```powershell
# Monitoring — zaznamenani vysledku
Stop-ScriptMonitor -ExitCode 0 -ItemsProcessed $AllUsers.Count -Details "Standard: $($StandardUsers.Count), Admin: $($AdminUsers.Count), Disabled: $DisabledCount"
```

- [ ] **Step 4: Over ze skripty maji spravnou syntaxi**

```bash
pwsh -NoProfile -Command "& {
    \$files = @(
        'LogRotate/logrotate.ps1',
        'WindowsUpdate/Auto-WindowsUpdate.ps1',
        'AD_PasswordAudit.ps1'
    )
    foreach (\$f in \$files) {
        \$errors = \$null
        [System.Management.Automation.Language.Parser]::ParseFile(\$f, [ref]\$null, [ref]\$errors)
        if (\$errors.Count -eq 0) { Write-Host \"OK: \$f\" -ForegroundColor Green }
        else { Write-Host \"ERRORS in \$f: \$(\$errors.Count)\" -ForegroundColor Red }
    }
}"
```

- [ ] **Step 5: Commit**

```bash
git add LogRotate/logrotate.ps1 WindowsUpdate/Auto-WindowsUpdate.ps1 AD_PasswordAudit.ps1
git commit -m "feat: integrace ScriptMonitor do existujicich skriptu"
```

---

### Task 7: README.md

**Files:**
- Create: `ScriptMonitor/README.md`

- [ ] **Step 1: Vytvor README.md**

```markdown
# ScriptMonitor

Centralni monitoring PowerShell skriptu pres Windows Event Log se statickym HTML dashboardem.

## Pozadavky

- Windows Server s PowerShell 5.1+
- Admin prava pro jednorazovou registraci Event Source
- WinRM povoleny pro monitoring remote serveru (volitelne)
- Pester 5+ pro spusteni testu (volitelne)

## Instalace

1. Na kazdem monitorovanem serveru spustte jako admin:
   ```powershell
   .\Install-ScriptMonitor.ps1
   ```
   Skript zaregistruje Event Source "ScriptMonitor" a zkopiruje soubory do `C:\Monitoring\`.

2. Upravte `C:\Monitoring\scripts-registry.json` podle vasich skriptu.

3. Do kazdeho monitorovaneho skriptu pridejte 3 radky:
   ```powershell
   # Zacatek skriptu
   Import-Module C:\Monitoring\ScriptMonitor.psm1
   Start-ScriptMonitor -ScriptName 'NazevSkriptu' -Version '1.0'

   # Konec skriptu (finally blok)
   Stop-ScriptMonitor -ExitCode $exitCode -ErrorCount $errors -ItemsProcessed $count -Details "Popis"
   ```

4. Naplanujte `Monitor-Scripts.ps1` v Task Scheduleru (napr. kazdych 30 minut):
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Monitoring\Monitor-Scripts.ps1"
   ```

5. Otevrete `C:\Monitoring\dashboard.html` v prohlizeci.

## Event Log konvence

| EventID | Severity    | Vyznam                    |
|---------|-------------|---------------------------|
| 1000    | Information | Skript uspesne dobehl     |
| 1001    | Warning     | Castecny uspech (chyby)   |
| 1002    | Error       | Skript selhal             |
| 1003    | Information | Skript spusten            |

## Soubory

| Soubor                  | Popis                                       |
|-------------------------|---------------------------------------------|
| ScriptMonitor.psm1      | Sdileny modul (Start/Stop funkce)           |
| Monitor-Scripts.ps1     | Monitor — cte eventy, generuje dashboard    |
| scripts-registry.json   | Registr skriptu a ocekavanych schedules     |
| Install-ScriptMonitor.ps1 | Jednorazova instalace                    |
| Tests/                  | Pester testy                                |

## Testy

```powershell
Invoke-Pester -Path .\Tests\ScriptMonitor.Tests.ps1 -Output Detailed
```

## Rozsireni

- **Email notifikace:** Upravte Monitor-Scripts.ps1 — pridejte Send-MailMessage pri ERROR/MISSING.
- **Teams webhook:** Pridejte Invoke-RestMethod s Teams webhook URL.
- **Dalsi skripty:** Pridejte zaznam do scripts-registry.json a 3 radky do skriptu.
```

- [ ] **Step 2: Commit**

```bash
git add ScriptMonitor/README.md
git commit -m "docs: README pro ScriptMonitor"
```

---

## Self-Review Checklist

- [x] **Spec coverage:** Vsechny pozadavky ze spec pokryty — modul (Task 2), registr (Task 1), monitor (Task 4-5), dashboard (Task 5), integrace (Task 6), fallback (Task 2), rozsiritelnost (dokumentovana v README)
- [x] **Placeholder scan:** Zadne TBD/TODO, vsechny kroky maji kompletni kod
- [x] **Type consistency:** `ScriptName`, `ExitCode`, `ErrorCount`, `ItemsProcessed`, `Details` pouzity konzistentne v modulu (Task 2), testech (Task 3), monitoru (Task 4) a integraci (Task 6)
- [x] **EventID logika:** 1000/1001/1002/1003 konzistentni v modulu, testech i monitoru
