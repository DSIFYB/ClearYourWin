#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Before, [Parameter(Mandatory)][string] $After)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/Comparison.psm1') -Force
$first = Get-Content -LiteralPath $Before -Raw -Encoding UTF8 | ConvertFrom-Json
$second = Get-Content -LiteralPath $After -Raw -Encoding UTF8 | ConvertFrom-Json
Compare-SystemSnapshots -Before $first -After $second | ConvertTo-Json -Depth 16
