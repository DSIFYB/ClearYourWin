#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('UserTemp','WindowsTemp','Both')][string] $Scope = 'UserTemp',
    [ValidateRange(7,365)][int] $MinAgeDays = 7,
    [ValidateRange(1,5000)][int] $MaxFiles = 1000,
    [ValidateRange(1,10737418240)][long] $MaxBytes = 2GB,
    [ValidateRange(1,100000)][int] $MaxEntries = 10000,
    [ValidateRange(1,120)][int] $ScanSeconds = 10,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../reports')
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Cleanup.psm1') -Force
$plan = New-CleanupPlan -Scope $Scope -MinAgeDays $MinAgeDays -MaxFiles $MaxFiles -MaxBytes $MaxBytes -MaxEntries $MaxEntries -ScanSeconds $ScanSeconds
Write-NewJson -Value $plan -Path (Join-Path $OutputDirectory ('cleanup-plan-' + $plan.planId + '.json'))
