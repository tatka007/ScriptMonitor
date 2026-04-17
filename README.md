# ScriptMonitor

Centralni monitoring PowerShell skriptu pres Windows Event Log se statickym HTML dashboardem.

**Verze:** 1.1 (2026-04-17)

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
   Podporuje `-WhatIf` pro nahled akci bez provedeni a `-Confirm` pro interaktivni potvrzeni.
   Skript zaregistruje Event Source "ScriptMonitor" a zkopiruje soubory do `C:\Monitoring\`.

   Volitelny parametr `-InstallPath` pro jinou cilovou cestu:
   ```powershell
   .\Install-ScriptMonitor.ps1 -InstallPath 'D:\Tools\Monitoring'
   ```

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

## Format Event Log zpravy

Kazdy event obsahuje strukturovana key:value pole:

```
ScriptName: LogRotate
Version: 1.0
Duration: 00:00:42
ExitCode: 0
ItemsProcessed: 15
ErrorCount: 0
Details: Rotace dokoncena
Server: SRV01
```

Pozn.: Moduly automaticky sanitizuji CR/LF v hodnotach, aby predesly injection
do parseru. Parser pouziva whitelist povolenych klicu a first-match-wins
strategii.

## Soubory

| Soubor                    | Popis                                       |
|---------------------------|---------------------------------------------|
| ScriptMonitor.psm1        | Sdileny modul (Start/Stop funkce)           |
| Monitor-Scripts.ps1       | Monitor — cte eventy, generuje dashboard    |
| scripts-registry.json     | Registr skriptu a ocekavanych schedules     |
| Install-ScriptMonitor.ps1 | Jednorazova instalace                       |
| Tests/                    | Pester testy (29 testu)                     |

## Registr skriptu (scripts-registry.json)

Pole `Name`, `Server`, `Schedule` jsou povinna. Schedule povolene hodnoty:
`daily`, `weekly`, `monthly`. Chybejici nebo neplatne pole zpusobi chybu.

| Pole            | Typ    | Povinne | Popis                                                   |
|-----------------|--------|---------|---------------------------------------------------------|
| Name            | string | ano     | Unikatni nazev skriptu (odpovida ScriptName v eventu)   |
| Server          | string | ano     | Hostname serveru (localhost nebo FQDN)                  |
| Schedule        | enum   | ano     | `daily`, `weekly`, `monthly`                            |
| ExpectedHour    | int    | ne      | Ocekavana hodina spusteni (0-23)                        |
| ExpectedDay     | mixed  | ne      | Den tydne (pro weekly) nebo den v mesici (pro monthly)  |
| MaxDurationMin  | int    | ne      | Maximalni doba behu v minutach (default: 60)            |
| Critical        | bool   | ne      | Oznaceni kritickeho skriptu (zobrazi se CRITICAL badge) |

## Pravidla vyhodnoceni statusu

| Status  | Kdy                                                                    |
|---------|------------------------------------------------------------------------|
| OK      | Posledni event je 1000 a neni starsi nez grace period podle Schedule   |
| WARNING | Posledni event je 1001                                                 |
| ERROR   | Posledni event je 1002, nebo RUNNING skript prekrocil MaxDurationMin   |
| RUNNING | Existuje 1003 (START) bez novejsiho STOP eventu                        |
| MISSING | Zadne eventy, nebo posledni OK beh je starsi nez grace period          |

Grace periody: daily = 36h, weekly = 192h (8 dni), monthly = 792h (33 dni).

## Public API modulu

### `Start-ScriptMonitor`

```powershell
Start-ScriptMonitor -ScriptName <string> [-Version <string>]
```

Zaznamena start skriptu (EventID 1003). `ScriptName` musi odpovidat Name
v scripts-registry.json. `Version` (default `0.0`) je pro audit trail.

### `Stop-ScriptMonitor`

```powershell
Stop-ScriptMonitor [-ScriptName <string>] [-ExitCode <int>] `
    [-ErrorCount <int>] [-ItemsProcessed <int>] [-Details <string>]
```

Zaznamena konec skriptu (EventID 1000/1001/1002 podle ExitCode a ErrorCount).
Pokud `ScriptName` neni uvedeno, pouzije se nejnovejsi aktivni Start (podle StartTime).

### `Test-MonitorEventSource`

```powershell
Test-MonitorEventSource
```

Vraci `$true`, pokud je Event Source "ScriptMonitor" registrovany.
Wrapper nad `[System.Diagnostics.EventLog]::SourceExists` — testovatelny pres Pester Mock.

## Testy

```powershell
Invoke-Pester -Path .\Tests\ScriptMonitor.Tests.ps1 -Output Detailed
```

Pokryti:
- **ScriptMonitor.psm1**: Start/Stop logika, sanitizace CR/LF, fallback log
- **Monitor-Scripts.ps1**: parser (first-match, whitelist), validace registry,
  vyhodnoceni statusu (OK/ERROR/RUNNING/MISSING), HTML encode, XSS, JS injection,
  DOM id sanitizace, Items=0 zobrazeni

Pocet testu: **29**.

## Bezpecnost

- Vsechna user-data v HTML dashboardu jsou HTML-encoded (`System.Net.WebUtility`).
- DOM id pro detail rows je sanitizovany whitelistem `[A-Za-z0-9_-]`.
- Event Log message parser pouziva whitelist povolenych klicu — zabrani override
  hodnot pres multi-line `Details` field.
- Start/Stop modul sanitizuje CR/LF ve vsech polich pred zapisem do Event Logu.
- Fallback log pouziva `FileShare.ReadWrite` — odolne vuci soubeznym zapisum.

## Rozsireni

- **Email notifikace:** Upravte `Invoke-MonitorScripts` v Monitor-Scripts.ps1 —
  pridejte `Send-MailMessage` pri ERROR/MISSING.
- **Teams webhook:** Pridejte `Invoke-RestMethod` s Teams webhook URL.
- **Dalsi skripty:** Pridejte zaznam do `scripts-registry.json` a 3 radky
  (`Import-Module` + `Start-ScriptMonitor` + `Stop-ScriptMonitor`) do skriptu.
