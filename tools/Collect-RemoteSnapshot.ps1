#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession] $Session,
    [string] $OutputDirectory = (Join-Path $PSScriptRoot '../reports'),
    [ValidateRange(1,10)][int] $SampleSeconds = 2,
    [switch] $IncludeThreads,
    [string[]] $ScanRoot = @(),
    [ValidateRange(1,1000000)][int] $MaxScanEntries = 10000,
    [ValidateRange(1,120)][int] $ScanSeconds = 10
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
if ($Session.State -ne 'Opened') { throw 'Provide an already opened, authorized PSSession.' }
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Raw -Encoding UTF8
# Only this trusted local module is executable input; snapshot data is never code.
$json = Invoke-Command -Session $Session -ArgumentList $source,$SampleSeconds,([bool]$IncludeThreads),$ScanRoot,$MaxScanEntries,$ScanSeconds -ScriptBlock {
    param($moduleSource,$seconds,$threads,$roots,$maxEntries,$scanTime)
    $ErrorActionPreference = 'Stop'
    $module = New-Module -Name WindowsCleanerRemote -ScriptBlock ([scriptblock]::Create($moduleSource))
    try {
        Import-Module $module
        Get-SystemSnapshot -SampleSeconds $seconds -IncludeThreads:$threads -ScanRoot @($roots) -MaxScanEntries $maxEntries -ScanSeconds $scanTime | ConvertTo-Json -Depth 32
    } finally { Remove-Module $module -ErrorAction SilentlyContinue }
}
$snapshot = $json | ConvertFrom-Json
$name = 'remote-{0}-{1}.json' -f [datetime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ'), [guid]::NewGuid().ToString('N').Substring(0,8)
Write-NewJson -Value $snapshot -Path (Join-Path $OutputDirectory $name)
