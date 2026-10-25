#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $Path,
    [string] $JournalDirectory = (Join-Path $PSScriptRoot '../backups'),
    [switch] $Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Cleanup.psm1') -Force
Assert-WindowsHost
$confirmation = @{}
if ($PSBoundParameters.ContainsKey('Confirm')) { $confirmation.Confirm = [bool]$PSBoundParameters['Confirm'] }
Invoke-CleanupPlan -Path $Path -JournalDirectory $JournalDirectory -Apply:$Apply -WhatIf:$WhatIfPreference @confirmation | ConvertTo-Json -Depth 16
