#Requires -Modules Pester

<#
.SYNOPSIS
    Pester testy pro ScriptMonitor.psm1 a funkce v Monitor-Scripts.ps1.
.NOTES
    Spusteni: Invoke-Pester -Path .\Tests\ScriptMonitor.Tests.ps1 -Output Detailed
#>

BeforeAll {
    # Na non-Windows platformach Write-EventLog neexistuje — stub pro moznost mockovani.
    # Na Windows se pouzije realny cmdlet a tento blok se preskoci.
    if (-not (Get-Command Write-EventLog -ErrorAction SilentlyContinue)) {
        function global:Write-EventLog {
            [CmdletBinding()]
            param(
                [string]$LogName,
                [string]$Source,
                [int]$EventId,
                [System.Diagnostics.EventLogEntryType]$EntryType,
                [string]$Message
            )
        }
    }

    $modulePath = Join-Path $PSScriptRoot '..\ScriptMonitor.psm1'
    Import-Module $modulePath -Force

    # Dot-source Monitor-Scripts.ps1 pro pristup k vnitrnim funkcim.
    # Entry point je ovinuty if $MyInvocation.InvocationName -ne '.', takze
    # pri dot-source se main logika neprovede.
    $monitorPath = Join-Path $PSScriptRoot '..\Monitor-Scripts.ps1'
    . $monitorPath

    # Helper — simuluje event objekt z Get-MonitorEvents se vsemi poly.
    function global:New-TestEvent {
        param(
            [int]$EventId,
            [datetime]$TimeCreated,
            [string]$ScriptName,
            [string]$Duration = '00:00:05',
            [string]$ExitCode = '0',
            [string]$ItemsProcessed = '0',
            [string]$ErrorCount = '0',
            [string]$Details = '',
            [string]$Server = 'h',
            [string]$Version = '1.0',
            [string]$EntryType = 'Information'
        )
        [PSCustomObject]@{
            EventId        = $EventId
            TimeCreated    = $TimeCreated
            EntryType      = $EntryType
            ScriptName     = $ScriptName
            Version        = $Version
            Duration       = $Duration
            ExitCode       = $ExitCode
            ItemsProcessed = $ItemsProcessed
            ErrorCount     = $ErrorCount
            Details        = $Details
            Server         = $Server
        }
    }
}

Describe 'Start-ScriptMonitor' {
    BeforeEach {
        Mock Write-EventLog {} -ModuleName ScriptMonitor
        Mock Test-MonitorEventSource { $true } -ModuleName ScriptMonitor
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

    It 'Odstrani CR/LF z nazvu skriptu (ochrana proti injection do parseru)' {
        Start-ScriptMonitor -ScriptName "Evil`nServer: attacker" -Version '1.0'

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -Times 1 -ParameterFilter {
            # Po sanitaci nesmi v Message byt druhy "Server:" radek s hodnotou attacker.
            ($Message -split "`n" | Where-Object { $_ -match '^Server:' }).Count -eq 1
        }
    }
}

Describe 'Stop-ScriptMonitor' {
    BeforeEach {
        Mock Write-EventLog {} -ModuleName ScriptMonitor
        Mock Test-MonitorEventSource { $true } -ModuleName ScriptMonitor
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

    It 'Pouzije nejnovejsi aktivni skript pokud ScriptName neuvedeno' {
        Start-ScriptMonitor -ScriptName 'Older'  -Version '1.0'
        Start-Sleep -Milliseconds 20
        Start-ScriptMonitor -ScriptName 'Newest' -Version '1.0'
        Stop-ScriptMonitor -ExitCode 0

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -ParameterFilter {
            $Message -match 'ScriptName: Newest'
        }
    }

    It 'Sanitizuje Details s CR/LF (nesmi rozbit parser)' {
        Stop-ScriptMonitor -ScriptName 'TestScript' -ExitCode 0 -Details "zero`nServer: attacker"

        Should -Invoke Write-EventLog -ModuleName ScriptMonitor -ParameterFilter {
            # V cele zprave smi byt jen jeden "Server:" radek a to ten legitimni.
            ($Message -split "`n" | Where-Object { $_ -match '^Server:' }).Count -eq 1
        }
    }
}

Describe 'Fallback log' {
    BeforeEach {
        # Simuluj selhani Event Logu
        Mock Write-EventLog { throw 'Access denied' } -ModuleName ScriptMonitor
        Mock Test-MonitorEventSource { $true } -ModuleName ScriptMonitor

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

# ===== Monitor-Scripts.ps1 =====

Describe 'ConvertFrom-MonitorMessage' {
    It 'Parsuje standardni zpravu' {
        $msg = @(
            'ScriptName: Foo'
            'Version: 1.0'
            'Duration: 00:00:05'
            'ExitCode: 0'
            'Server: HOST'
        ) -join "`n"

        $result = ConvertFrom-MonitorMessage -RawMessage $msg
        $result['ScriptName'] | Should -Be 'Foo'
        $result['Version']    | Should -Be '1.0'
        $result['Duration']   | Should -Be '00:00:05'
        $result['ExitCode']   | Should -Be '0'
        $result['Server']     | Should -Be 'HOST'
    }

    It 'Nepripusti override Server pres multi-line Details (first-match wins)' {
        $msg = @(
            'ScriptName: Foo'
            'Server: LEGIT-HOST'
            'Details: first line'
            'Server: ATTACKER'
        ) -join "`n"

        $result = ConvertFrom-MonitorMessage -RawMessage $msg
        $result['Server'] | Should -Be 'LEGIT-HOST'
    }

    It 'Ignoruje neznama pole mimo whitelist' {
        $msg = @(
            'ScriptName: Foo'
            'MaliciousField: payload'
        ) -join "`n"

        $result = ConvertFrom-MonitorMessage -RawMessage $msg
        $result.ContainsKey('MaliciousField') | Should -BeFalse
    }
}

Describe 'Test-RegistryEntry' {
    It 'Vyhodi chybu pri chybejicim Name' {
        $entry = [PSCustomObject]@{ Server = 'host'; Schedule = 'daily' }
        { Test-RegistryEntry -Entry $entry } | Should -Throw
    }

    It 'Vyhodi chybu pri neplatnem Schedule' {
        $entry = [PSCustomObject]@{ Name = 'X'; Server = 'h'; Schedule = 'yearly' }
        { Test-RegistryEntry -Entry $entry } | Should -Throw
    }

    It 'Nevyhodi chybu pri platnem zaznamu' {
        $entry = [PSCustomObject]@{ Name = 'X'; Server = 'h'; Schedule = 'daily' }
        { Test-RegistryEntry -Entry $entry } | Should -Not -Throw
    }
}

Describe 'Get-ScriptStatus' {
    It 'MISSING pri zadnych eventech' {
        $entry = [PSCustomObject]@{ Name = 'Foo'; Server = 'h'; Schedule = 'daily'; Critical = $false }
        $s = Get-ScriptStatus -RegistryEntry $entry -Events @()
        $s.Status | Should -Be 'MISSING'
    }

    It 'OK pri nedavnem STOP eventu 1000' {
        $entry = [PSCustomObject]@{ Name = 'Foo'; Server = 'h'; Schedule = 'daily'; Critical = $false }
        $events = @(
            New-TestEvent -EventId 1000 -TimeCreated (Get-Date).AddMinutes(-10) -ScriptName 'Foo' -Details 'ok'
        )
        $s = Get-ScriptStatus -RegistryEntry $entry -Events $events
        $s.Status | Should -Be 'OK'
    }

    It 'ERROR pri STOP eventu 1002' {
        $entry = [PSCustomObject]@{ Name = 'Foo'; Server = 'h'; Schedule = 'daily'; Critical = $false }
        $events = @(
            New-TestEvent -EventId 1002 -TimeCreated (Get-Date).AddMinutes(-10) -ScriptName 'Foo' -ExitCode '1' -Details 'bum'
        )
        $s = Get-ScriptStatus -RegistryEntry $entry -Events $events
        $s.Status | Should -Be 'ERROR'
    }

    It 'RUNNING pri START bez STOP' {
        $entry = [PSCustomObject]@{ Name = 'Foo'; Server = 'h'; Schedule = 'daily'; Critical = $false; MaxDurationMin = 60 }
        $events = @(
            New-TestEvent -EventId 1003 -TimeCreated (Get-Date).AddMinutes(-5) -ScriptName 'Foo'
        )
        $s = Get-ScriptStatus -RegistryEntry $entry -Events $events
        $s.Status | Should -Be 'RUNNING'
    }

    It 'ERROR pri dlouho bezicim skriptu (nad MaxDurationMin)' {
        $entry = [PSCustomObject]@{ Name = 'Foo'; Server = 'h'; Schedule = 'daily'; Critical = $false; MaxDurationMin = 5 }
        $events = @(
            New-TestEvent -EventId 1003 -TimeCreated (Get-Date).AddMinutes(-30) -ScriptName 'Foo'
        )
        $s = Get-ScriptStatus -RegistryEntry $entry -Events $events
        $s.Status | Should -Be 'ERROR'
    }

    It 'MISSING pri starem OK eventu (daily nad 36h)' {
        $entry = [PSCustomObject]@{ Name = 'Foo'; Server = 'h'; Schedule = 'daily'; Critical = $false }
        $events = @(
            New-TestEvent -EventId 1000 -TimeCreated (Get-Date).AddHours(-40) -ScriptName 'Foo'
        )
        $s = Get-ScriptStatus -RegistryEntry $entry -Events $events
        $s.Status | Should -Be 'MISSING'
    }
}

Describe 'ConvertTo-HtmlSafe' {
    It 'Zakoduje HTML znaky' {
        (ConvertTo-HtmlSafe '<script>alert(1)</script>') | Should -Be '&lt;script&gt;alert(1)&lt;/script&gt;'
    }

    It 'Vrati prazdny retezec pri null/empty vstupu' {
        (ConvertTo-HtmlSafe $null) | Should -Be ''
        (ConvertTo-HtmlSafe '')    | Should -Be ''
    }
}

Describe 'ConvertTo-SafeDomId' {
    It 'Nahradi nebezpecne znaky podtrzitkem' {
        (ConvertTo-SafeDomId 'a''b"c)d') | Should -Be 'detail-a_b_c_d'
    }

    It 'Zachova alfanumericke znaky a pomlcku' {
        (ConvertTo-SafeDomId 'My-Script_1') | Should -Be 'detail-My-Script_1'
    }
}

Describe 'ConvertTo-DashboardHtml' {
    It 'Neobsahuje neescapovany skript tag v ScriptName (XSS)' {
        $statuses = @(
            [PSCustomObject]@{
                Name       = '<script>alert(1)</script>'
                Server     = 'host'
                Status     = 'OK'
                LastRun    = Get-Date
                Duration   = '00:00:01'
                Details    = 'ok'
                ExitCode   = '0'
                Critical   = $false
                RecentRuns = @()
            }
        )
        $html = ConvertTo-DashboardHtml -Statuses $statuses
        $html | Should -Not -Match '<script>alert\(1\)</script>'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt;'
    }

    It 'Neobsahuje JS injection pres apostrof v ScriptName' {
        $statuses = @(
            [PSCustomObject]@{
                Name       = "Foo'+alert(1)+'"
                Server     = 'h'
                Status     = 'OK'
                LastRun    = Get-Date
                Duration   = '00:00:01'
                Details    = ''
                ExitCode   = '0'
                Critical   = $false
                RecentRuns = @()
            }
        )
        $html = ConvertTo-DashboardHtml -Statuses $statuses
        # data-detail musi obsahovat jen bezpecne znaky ([A-Za-z0-9_-] po sanitaci).
        $html | Should -Not -Match "data-detail=`"detail-Foo'"
        $html | Should -Match 'data-detail="detail-Foo__alert_1___"'
    }

    It 'Zobrazi 0 v Items (ne skryte pres falsy check)' {
        $statuses = @(
            [PSCustomObject]@{
                Name       = 'Foo'
                Server     = 'h'
                Status     = 'OK'
                LastRun    = Get-Date
                Duration   = '00:00:01'
                Details    = ''
                ExitCode   = '0'
                Critical   = $false
                RecentRuns = @(
                    [PSCustomObject]@{
                        Time    = Get-Date
                        EventId = 1000
                        Duration = '00:00:01'
                        Items   = 0
                        Details = ''
                    }
                )
            }
        )
        $html = ConvertTo-DashboardHtml -Statuses $statuses
        # Ocekavame <td>0</td> v detailni tabulce, ne <td>-</td>.
        $html | Should -Match '<td>0</td>'
    }
}
