# Script Monitoring System — Design Spec

**Datum:** 2026-04-15
**Autor:** Petr Pavlas / Claude AI
**Status:** Schvaleno

---

## Cil

Centralni prehled nad vsemi automatizovanymi PowerShell skripty bezicimi na 1-3 Windows serverech. Zadne externi nastroje — nativni Windows Event Log + staticka HTML stranka.

## Pozadavky

- Centralni misto kde videt status vsech skriptu
- Detekce: selhani, neprobehnuti, prilis dlouhy beh
- Minimalni zasah do stavajicich skriptu (3 radky)
- Rozsiritelne o email/Teams notifikace v budoucnosti
- Kompatibilni s existujicim workflow (C:\LOGS, Task Scheduler, GitHub repo)

---

## Architektura

```
Scripty (LogRotate, WinUpdate, AD_PwdAudit, ...)
    |
    v
Windows Event Log (Application), Source: "ScriptMonitor"
    |
    v
Monitor-Scripts.ps1 (Task Scheduler, kazdych 30 min)
    |
    v
C:\Monitoring\dashboard.html (staticka HTML stranka)
```

### Event Log konvence

| EventID | Severity    | Vyznam                        |
|---------|-------------|-------------------------------|
| 1000    | Information | Skript dobehl uspesne         |
| 1001    | Warning     | Castecny uspech (s chybami)   |
| 1002    | Error       | Skript selhal                 |
| 1003    | Information | Skript spusten (heartbeat)    |

### Message format v Event Logu

```
ScriptName: LogRotate
Version: 2.1
Duration: 00:02:34
ExitCode: 0
ItemsProcessed: 12
ErrorCount: 0
Details: Zpracovano 12 jobu, 0 chyb
Server: SRV-FILE01
```

---

## Komponenty

### 1. ScriptMonitor.psm1 — sdileny modul

Umisteni: `C:\Monitoring\ScriptMonitor.psm1`

**Funkce:**
- `Start-ScriptMonitor -ScriptName -Version` — zapise EventID 1003 (STARTED), spusti stopky
- `Stop-ScriptMonitor -ExitCode -ItemsProcessed -ErrorCount -Details` — vypocita dobu behu, zvoli EventID dle logiky:
  - ExitCode = 0 a ErrorCount = 0 → EventID 1000 (SUCCESS)
  - ExitCode = 0 a ErrorCount > 0 → EventID 1001 (WARNING, castecny uspech)
  - ExitCode != 0 → EventID 1002 (ERROR)
  Zapise strukturovanou zpravu do Event Logu
- Automaticka registrace Event Source "ScriptMonitor" (jednorazove, admin)
- Fallback: pokud Event Log neni dostupny → `C:\Monitoring\fallback.log`

**Integrace do existujicich skriptu (3 radky):**
```powershell
# Na zacatku:
Import-Module C:\Monitoring\ScriptMonitor.psm1
Start-ScriptMonitor -ScriptName "LogRotate" -Version "2.1"

# Na konci (finally blok):
Stop-ScriptMonitor -ExitCode $ExitCode -ItemsProcessed $count -Details "Zpracovano $count jobu"
```

### 2. scripts-registry.json — registr skriptu

Umisteni: `C:\Monitoring\scripts-registry.json`

Definuje co ma kdy bezet:
```json
[
  {
    "Name": "LogRotate",
    "Server": "SRV-FILE01",
    "Schedule": "daily",
    "ExpectedHour": 3,
    "MaxDurationMin": 30,
    "Critical": false
  },
  {
    "Name": "Auto-WindowsUpdate",
    "Server": "SRV-DC01",
    "Schedule": "weekly",
    "ExpectedDay": "Sunday",
    "ExpectedHour": 2,
    "MaxDurationMin": 180,
    "Critical": true
  },
  {
    "Name": "AD_PasswordAudit",
    "Server": "SRV-DC01",
    "Schedule": "monthly",
    "ExpectedDay": 1,
    "MaxDurationMin": 10,
    "Critical": false
  }
]
```

### 3. Monitor-Scripts.ps1 — hlavni monitor

Umisteni: `C:\Monitoring\Monitor-Scripts.ps1`
Schedule: Task Scheduler, kazdych 30 minut

**Postup:**
1. Nacte `scripts-registry.json`
2. Pro kazdy skript dotahne posledni eventy z Event Logu (`Get-WinEvent`)
3. Pro remote servery: `Get-WinEvent -ComputerName $server` (vyzaduje WinRM)
4. Vyhodnoti status:
   - **OK** — posledni beh uspesny, v ramci schedule
   - **WARNING** — castecne chyby, nebo se blizi deadline
   - **ERROR** — posledni beh selhal
   - **MISSING** — skript neprobehl v ocekavanem intervalu
   - **RUNNING** — ma START event ale zadny STOP
5. Vygeneruje `dashboard.html`

### 4. dashboard.html — vystup

Umisteni: `C:\Monitoring\dashboard.html`

- Staticka HTML stranka s inline CSS (zadne externi zavislosti)
- Auto-refresh meta tag kazdych 5 minut
- Souhrnny radek: pocet OK / WARNING / ERROR / MISSING
- Tabulka: Skript | Server | Status | Posledni beh | Doba behu
- Collapsible detail: poslednich 5 behu kazdeho skriptu
- Barvy: OK = zelena, WARNING = zluta, ERROR = cervena, MISSING = seda

---

## Adresarova struktura

```
C:\Monitoring\
├── ScriptMonitor.psm1          # Sdileny modul
├── Monitor-Scripts.ps1          # Monitor + HTML generator
├── scripts-registry.json        # Registr skriptu
├── dashboard.html               # Vystup
└── fallback.log                 # Fallback log
```

GitHub: `tatka007/PowerShell/ScriptMonitor/` s README.md

---

## Rozsiritelnost

Architektura je pripravena na:
- **Email/Teams notifikace** — podminky v Monitor-Scripts.ps1: pokud ERROR/MISSING → Send-MailMessage / Teams webhook
- **Vice serveru** — pridat do scripts-registry.json, WinRM uz je v designu
- **Historicke trendy** — appendovat do CSV, dashboard zobrazi trend doby behu
- **SentinelOne integrace** — Event Log eventy automaticky viditelne pokud SentinelOne sbira Application log

---

## Predpoklady a omezeni

- WinRM musi byt povoleny pro cteni Event Logu z remote serveru
- Registrace Event Source vyzaduje jednorazove spusteni s admin pravy
- Dashboard neni real-time — aktualizace dle intervalu Task Scheduleru (30 min)
- Event Log ma vychozi retenci (zpravidla 20 MB) — dostacujici pro tento objem
