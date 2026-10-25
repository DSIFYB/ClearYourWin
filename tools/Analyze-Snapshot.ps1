#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Path, [switch] $AsJson)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
$snapshot = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
$findings = @(Get-SnapshotFindings -Snapshot $snapshot)
if ($AsJson) {
    ConvertTo-Json -InputObject $findings -Depth 16
} else {
    Write-Output ('Computer: {0}; snapshot: {1}; findings: {2}' -f $snapshot.computerName, $snapshot.finishedAtUtc, $findings.Count)
    foreach ($finding in $findings) {
        Write-Output ('[{0}] {1}' -f $finding.severity, $finding.id)
        Write-Output ('  Evidence: ' + ($finding.evidence | ConvertTo-Json -Depth 8 -Compress))
        Write-Output ('  Action: ' + $finding.recommendation)
    }
    if ($findings.Count -eq 0) { Write-Output 'No rules triggered. This does not certify performance or safety.' }
}
