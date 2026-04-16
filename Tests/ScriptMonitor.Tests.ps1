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
