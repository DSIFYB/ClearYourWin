#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $project 'lib/WindowsCleaner.psm1') -Force
Import-Module (Join-Path $project 'lib/Startup.psm1') -Force
$script:passed = 0
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Output ('PASS ' + $Name) }
function Expect-Throw([scriptblock]$Body) {
    $thrown = $false
    try { & $Body | Out-Null } catch { $thrown = $true }
    Assert $thrown 'Expected an exception.'
}
function New-Fixture {
    $sections = [ordered]@{}
    foreach ($name in @('system','processes','threads','startup','services','drivers','systemDrivers','devices','disks','applications','defender','diskScan')) {
        $sections[$name] = [pscustomobject]@{ status = 'ok'; items = @(); errors = @() }
    }
    [pscustomobject]@{ schemaVersion = 1; computerName = 'fixture'; finishedAtUtc = '2026-01-01T00:00:00Z'; sections = [pscustomobject]$sections }
}
$scratch = Join-Path $PSScriptRoot ('.tmp-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$junction = Join-Path $scratch 'scan/link'
try {
    Test 'PowerShell source parses' {
        foreach ($file in (Get-ChildItem -LiteralPath $project -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
            $tokens = $null; $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            Assert ($parseErrors.Count -eq 0) ($file.FullName + ': ' + ($parseErrors -join '; '))
        }
    }
    Test 'Empty valid snapshot has no fabricated findings' {
        Assert (@(Get-SnapshotFindings (New-Fixture)).Count -eq 0) 'Unexpected findings.'
    }
    Test 'Process identity tolerates CIM precision but rejects reused PID' {
        & (Get-Module WindowsCleaner) {
            $cimDate = [datetime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            if (-not (Test-SameProcessStart $cimDate $cimDate.AddTicks(5))) { throw 'CIM rounding rejected the same process.' }
            if (Test-SameProcessStart $cimDate $cimDate.AddSeconds(1)) { throw 'Reused PID accepted.' }
        }
    }
    Test 'Tasks without triggers do not break startup enumeration' {
        & (Get-Module WindowsCleaner) {
            if (Test-StartupTrigger $null) { throw 'Null trigger was accepted.' }
            $trigger = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' } }
            if (-not (Test-StartupTrigger $trigger)) { throw 'Logon trigger missing.' }
            $trigger.CimClass.CimClassName = 'MSFT_TaskDailyTrigger'
            if (Test-StartupTrigger $trigger) { throw 'Daily trigger was accepted.' }
        }
    }
    Test 'Warnings retain evidence and ignore idle process' {
        $fixture = New-Fixture
        $fixture.sections.system.items = @([pscustomobject]@{ totalMemoryBytes = 1000; freeMemoryBytes = 100 })
        $fixture.sections.processes.items = @([pscustomobject]@{ id = 0; name = 'Idle'; cpuPercent = 99 }, [pscustomobject]@{ id = 42; name = 'test'; cpuPercent = 30 })
        $fixture.sections.disks.items = @([pscustomobject]@{ DeviceID = 'C:'; Size = 1000; FreeSpace = 50 })
        $fixture.sections.devices.items = @([pscustomobject]@{ Name = 'test'; DeviceID = 'device'; ConfigManagerErrorCode = 28 })
        $fixture.sections.defender.items = @([pscustomobject]@{ AntivirusEnabled = $true; RealTimeProtectionEnabled = $false; AntivirusSignatureAge = 10; AMRunningMode = 'Passive' })
        $results = @(Get-SnapshotFindings $fixture)
        Assert ($results.Count -eq 6) ('Expected 6 findings, got ' + $results.Count)
        Assert ($results.id -notcontains 'cpu.0') 'Idle was counted as CPU load.'
        Assert (($results | Where-Object id -eq 'cpu.42').evidence.cpuPercent -eq 30) 'Lost CPU evidence.'
    }
    Test 'Partial sections are explicitly reported' {
        $fixture = New-Fixture
        $fixture.sections.drivers.status = 'error'
        $fixture.sections.drivers.errors = @('Access denied')
        $results = @(Get-SnapshotFindings $fixture)
        Assert ($results[0].id -eq 'coverage.drivers') 'Missing coverage finding.'
        Assert ($results[0].evidence -match 'Access denied') 'Missing error evidence.'
    }
    Test 'Unsupported and malformed snapshots fail' {
        $fixture = New-Fixture; $fixture.schemaVersion = 999
        Expect-Throw { Get-SnapshotFindings $fixture }
        $fixture = New-Fixture; $fixture.sections.PSObject.Properties.Remove('services')
        Expect-Throw { Get-SnapshotFindings $fixture }
    }
    Test 'JSON writes round trip and refuse overwrite' {
        $target = Join-Path $scratch 'report.json'
        $null = Write-NewJson -Path $target -Value (New-Fixture)
        $roundtrip = Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert ($roundtrip.schemaVersion -eq 1) 'Invalid round trip.'
        Assert (@($roundtrip.sections.system.items).Count -eq 0) 'Empty array was not preserved.'
        Expect-Throw { Write-NewJson -Path $target -Value @{ changed = $true } }
    }
    $scan = Join-Path $scratch 'scan'
    $null = New-Item -ItemType Directory -Path $scan
    1..10 | ForEach-Object { [IO.File]::WriteAllText((Join-Path $scan ('file[' + $_ + '].exe')), 'test') }
    Test 'File scan totals and literal filenames' {
        $result = @(Get-DiskScan -Root @($scan) -MaxEntries 100 -Seconds 5)[0]
        Assert ($result.fileCount -eq 10 -and $result.scannedBytes -eq 40) 'Incorrect scan totals.'
        Assert ($result.executableCount -eq 10) 'Missing executable candidates.'
        Assert ($result.oldTempBytes -eq 0 -and -not $result.isDefaultTemp) 'Arbitrary root marked as garbage.'
        Assert $result.complete 'Unexpected incomplete scan.'
    }
    Test 'Entry budget limits work and marks incompleteness' {
        $result = @(Get-DiskScan -Root @($scan) -MaxEntries 3 -Seconds 5)[0]
        Assert ($result.visitedEntries -eq 3) 'Entry budget exceeded.'
        Assert ($result.limited -and -not $result.complete) 'Limit was not reported.'
    }
    Test 'Missing root is not a clean bill of health' {
        $result = @(Get-DiskScan -Root @((Join-Path $scratch 'missing')) -MaxEntries 3 -Seconds 5)[0]
        Assert (-not $result.complete -and $result.errors.Count -gt 0) 'Missing directory was hidden.'
    }
    Test 'Reparse links and linked roots are skipped' {
        $outside = Join-Path $scratch 'outside'
        $null = New-Item -ItemType Directory -Path $outside
        [IO.File]::WriteAllText((Join-Path $outside 'secret.txt'), 'outside')
        $null = New-Item -ItemType Junction -Path $junction -Target $outside
        $result = @(Get-DiskScan -Root @($scan) -MaxEntries 100 -Seconds 5)[0]
        Assert ($result.skippedReparsePoints -eq 1 -and $result.fileCount -eq 10) 'Followed reparse point.'
        $linked = @(Get-DiskScan -Root @($junction) -MaxEntries 100 -Seconds 5)[0]
        Assert (-not $linked.complete -and $linked.fileCount -eq 0) 'Followed linked scan root.'
    }
    Test 'Cleanup candidates require actual TEMP root' {
        $previousTemp = $env:TEMP
        try {
            $env:TEMP = $scan
            $filePath = Join-Path $scan 'file[1].exe'
            [IO.File]::SetLastWriteTimeUtc($filePath, [datetime]::UtcNow.AddDays(-10))
            $result = @(Get-DiskScan -Root @($scan) -MaxEntries 100 -Seconds 5)[0]
            Assert ($result.oldTempBytes -eq 4 -and $result.oldTempFileCount -eq 1) 'Old TEMP candidate calculation failed.'
            $fixture = New-Fixture; $fixture.sections.diskScan.items = @($result)
            $findings = @(Get-SnapshotFindings $fixture)
            Assert ($findings.category -contains 'cleanup' -and $findings.category -contains 'file-review') 'Missing scan findings.'
        } finally { $env:TEMP = $previousTemp }
    }
    Test 'Startup backup validation binds target and preserves unexpanded string' {
        $identity = [pscustomobject]@{ computerName = 'test-pc'; userSid = 'S-1-5-21-test' }
        $backup = [pscustomobject]@{ schemaVersion = 1; action = 'disable-hkcu-run'; computerName = 'test-pc'
            userSid = 'S-1-5-21-test'; registrySubkey = 'Software\Microsoft\Windows\CurrentVersion\Run'
            createdAtUtc = '2026-01-01T00:00:00Z'; entry = [pscustomobject]@{ name = 'Test'; value = '%LOCALAPPDATA%\app.exe'; kind = 'ExpandString' } }
        Assert-StartupBackup $backup $identity
        Assert ($backup.entry.value -ceq '%LOCALAPPDATA%\app.exe') 'Expanded a registry string.'
        $backup.userSid = 'another-user'; Expect-Throw { Assert-StartupBackup $backup $identity }
        $backup.userSid = $identity.userSid; $backup.registrySubkey = 'Software\Other'
        Expect-Throw { Assert-StartupBackup $backup $identity }
        $backup.registrySubkey = 'Software\Microsoft\Windows\CurrentVersion\Run'; $backup.entry.kind = 'DWord'
        Expect-Throw { Assert-StartupBackup $backup $identity }
    }
    Test 'WhatIf returns before writes using isolated module mocks' {
        $module = Get-Module Startup
        & $module {
            function script:Get-RunEntry { param($Name) [pscustomobject]@{ name = $Name; value = 'test'; kind = 'String' } }
            function script:Get-StartupIdentity { throw 'WhatIf reached mutation branch.' }
            Disable-RunEntry -Name 'synthetic' -BackupDirectory 'unused' -Apply -WhatIf
        }
    }
    . (Join-Path $PSScriptRoot 'Test-Actions.ps1') -Scratch $scratch
    Write-Output ('All {0} tests passed. Only workspace fixture files were cleaned; no system settings or real startup values changed.' -f $script:passed)
} finally {
    # Remove the junction itself before recursive cleanup; never traverse its target.
    if ([IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction) }
    $resolvedScratch = [IO.Path]::GetFullPath($scratch)
    $allowedParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if (-not $resolvedScratch.StartsWith($allowedParent, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedScratch -Recurse -Force
}
