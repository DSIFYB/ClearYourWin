#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Name,
    [string] $BackupDirectory = (Join-Path $PSScriptRoot '../backups'),
    [switch] $Apply
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
Import-Module (Join-Path $PSScriptRoot '../lib/Startup.psm1') -Force
Assert-WindowsHost
$confirmation = @{}
if ($PSBoundParameters.ContainsKey('Confirm')) { $confirmation.Confirm = [bool]$PSBoundParameters['Confirm'] }
Disable-RunEntry -Name $Name -BackupDirectory $BackupDirectory -Apply:$Apply -WhatIf:$WhatIfPreference @confirmation | ConvertTo-Json -Depth 8
