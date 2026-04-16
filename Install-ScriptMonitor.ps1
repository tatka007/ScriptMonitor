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
