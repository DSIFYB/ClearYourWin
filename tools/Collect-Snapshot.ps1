#requires -Version 5.1
[CmdletBinding()]
param(
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../reports'),
    [ValidateRange(1,10)][int] $SampleSeconds = 2,
    [switch] $IncludeThreads,
    [string[]] $ScanRoot = @(),
    [ValidateRange(1,1000000)][int] $MaxScanEntries = 10000,
    [ValidateRange(1,120)][int] $ScanSeconds = 10
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
$snapshot = Get-SystemSnapshot -SampleSeconds $SampleSeconds -IncludeThreads:$IncludeThreads -ScanRoot $ScanRoot -MaxScanEntries $MaxScanEntries -ScanSeconds $ScanSeconds
$name = 'snapshot-{0}-{1}.json' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N').Substring(0,8)
Write-NewJson -Value $snapshot -Path (Join-Path $OutputDirectory $name)
