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
