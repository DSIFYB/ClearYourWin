#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string] $Path, [ValidateRange(1,4096)][int] $MaxMegabytes = 256)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../lib/WindowsCleaner.psm1') -Force
Assert-WindowsHost
$file = Get-Item -LiteralPath $Path -Force
if ($file.PSIsContainer -or $file.PSProvider.Name -ne 'FileSystem') { throw 'Select one filesystem file.' }
if ($file.Length -gt ($MaxMegabytes * 1MB)) { throw 'File exceeds inspection size limit. Increase MaxMegabytes explicitly if needed.' }
$before = @{ length = $file.Length; lastWrite = $file.LastWriteTimeUtc }
$hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
$signature = Get-AuthenticodeSignature -LiteralPath $file.FullName
$file.Refresh()
if (-not $file.Exists -or $before.length -ne $file.Length -or $before.lastWrite -ne $file.LastWriteTimeUtc) { throw 'File changed during inspection; repeat before drawing conclusions.' }
[pscustomobject]@{
    path = $file.FullName; bytes = $file.Length; lastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
    sha256 = $hash.Hash; signatureStatus = $signature.Status.ToString()
    signer = $(if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { $null })
    company = $file.VersionInfo.CompanyName; product = $file.VersionInfo.ProductName
    note = 'No file execution. Signature checks may use Windows trust/revocation services. Hash/signature are not a malware verdict.'
} | ConvertTo-Json -Depth 5
