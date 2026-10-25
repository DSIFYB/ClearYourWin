#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateSet('AnalyzeComponentStore','CleanComponentStore','AnalyzeVolume','OptimizeVolume','FlushDns','VerifySystemFiles')][string] $Action,
    [string] $DriveLetter,
    [string] $JournalDirectory = (Join-Path $PSScriptRoot '../backups'),
    [switch] $Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Maintenance.psm1') -Force
$confirmation = @{}
if ($PSBoundParameters.ContainsKey('Confirm')) { $confirmation.Confirm = [bool]$PSBoundParameters['Confirm'] }
Invoke-WindowsMaintenance -Action $Action -DriveLetter $DriveLetter -JournalDirectory $JournalDirectory -Apply:$Apply -WhatIf:$WhatIfPreference @confirmation | ConvertTo-Json -Depth 12
