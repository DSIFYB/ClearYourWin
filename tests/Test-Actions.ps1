#requires -Version 5.1
param([Parameter(Mandatory)][string] $Scratch)

Import-Module (Join-Path $project 'lib/Cleanup.psm1') -Force
Import-Module (Join-Path $project 'lib/Maintenance.psm1') -Force
Import-Module (Join-Path $project 'lib/Comparison.psm1') -Force
$actionRoot = Join-Path $Scratch 'actions'
$tempRoot = Join-Path $actionRoot 'temp'
$actionJournals = Join-Path $actionRoot 'journals'
$null = [IO.Directory]::CreateDirectory($tempRoot)
$cleanupModule = Get-Module Cleanup
# All destructive tests are bound to this workspace fixture, never real TEMP.
& $cleanupModule {
    param($Root)
    $script:fixtureRoot = $Root
    function script:Get-CleanupRoots { param($Scope) return $script:fixtureRoot }
} $tempRoot

function New-OldFixtureFile([string] $Name, [string] $Content = 'old-data') {
    $filePath = Join-Path $tempRoot $Name
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($filePath))
    [IO.File]::WriteAllText($filePath, $Content)
    [IO.File]::SetCreationTimeUtc($filePath, [datetime]::UtcNow.AddDays(-10))
    [IO.File]::SetLastWriteTimeUtc($filePath, [datetime]::UtcNow.AddDays(-10))
    return $filePath
}
function Save-FixturePlan($Plan) {
    Write-NewJson -Value $Plan -Path (Join-Path $actionRoot ([guid]::NewGuid().ToString('N') + '.json'))
}

Test 'Cleanup native verifier compiles and detects eligible files' {
    $script:oldFixture = New-OldFixtureFile 'old[1].tmp'
    $script:changedFixture = New-OldFixtureFile 'nested/changed.log'
    $null = New-OldFixtureFile 'installer.exe'
    [IO.File]::WriteAllText((Join-Path $tempRoot 'recent.tmp'), 'new')
    $script:cleanupPlan = New-CleanupPlan
    Assert (@($script:cleanupPlan.items).Count -eq 2) ('Expected 2 old non-executable files. Errors: ' + ($script:cleanupPlan.errors -join '; '))
    Assert ($script:cleanupPlan.candidateBytes -eq 16) 'Invalid candidate byte total.'
    $script:cleanupPlanPath = Save-FixturePlan $script:cleanupPlan
}
Test 'Cleanup preview and WhatIf do not create journals or delete files' {
    $preview = Invoke-CleanupPlan -Path $script:cleanupPlanPath -JournalDirectory $actionJournals
    Assert ($preview.mode -eq 'preview' -and $preview.files -eq 2) 'Invalid preview.'
    Invoke-CleanupPlan -Path $script:cleanupPlanPath -JournalDirectory $actionJournals -Apply -WhatIf
    Assert ([IO.File]::Exists($script:oldFixture)) 'Preview deleted a file.'
    Assert (-not [IO.Directory]::Exists($actionJournals)) 'Preview wrote a journal.'
}
Test 'Cleanup deletes verified fixture and skips a changed file with audit' {
    [IO.File]::AppendAllText($script:changedFixture, 'changed')
    $applied = Invoke-CleanupPlan -Path $script:cleanupPlanPath -JournalDirectory $actionJournals -Apply -Confirm:$false
    Assert ($applied.deleted -eq 1 -and $applied.skipped -eq 1 -and $applied.deletedBytes -eq 8) 'Incorrect cleanup results.'
    Assert (-not [IO.File]::Exists($script:oldFixture)) 'Approved file remains.'
    Assert ([IO.File]::Exists($script:changedFixture) -and [IO.File]::Exists((Join-Path $tempRoot 'recent.tmp'))) 'Changed/recent file was removed.'
    $events = @(Get-Content -LiteralPath $applied.journalPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert ($events[0].event -eq 'begin' -and $events[-1].event -eq 'end') 'Audit is incomplete.'
    Assert (@($events | Where-Object event -eq 'intent').Count -eq 2) 'Intent was not recorded for each attempt.'
}
Test 'Repeated cleanup is safe and does not delete replacement files' {
    [IO.File]::WriteAllText($script:oldFixture, 'replacement')
    $repeated = Invoke-CleanupPlan -Path $script:cleanupPlanPath -JournalDirectory $actionJournals -Apply -Confirm:$false
    Assert ($repeated.deleted -eq 0 -and $repeated.skipped -eq 2) 'Repeated plan deleted changed files.'
    Assert ([IO.File]::ReadAllText($script:oldFixture) -eq 'replacement') 'Replacement was changed.'
}
Test 'Locked file is skipped without forcing access' {
    $lockedPath = New-OldFixtureFile 'locked.tmp'
    $lockedPlan = New-CleanupPlan
    $lockedPlan.items = @($lockedPlan.items | Where-Object { $_.file.Path -eq $lockedPath })
    $lockedPlan.candidateBytes = 8
    $planPath = Save-FixturePlan $lockedPlan
    $lock = [IO.File]::Open($lockedPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $applied = Invoke-CleanupPlan -Path $planPath -JournalDirectory $actionJournals -Apply -Confirm:$false
        Assert ($applied.deleted -eq 0 -and $applied.skipped -eq 1) 'Locked file was not skipped.'
    } finally { $lock.Dispose() }
}
Test 'File identity rejects replacement with identical size and timestamps' {
    $targetPath = New-OldFixtureFile 'identity.tmp'
    $candidate = New-CleanupPlan
    $candidate.items = @($candidate.items | Where-Object { $_.file.Path -eq $targetPath }); $candidate.candidateBytes = 8
    $filePath = Save-FixturePlan $candidate
    $original = $candidate.items[0].file
    [IO.File]::Move($targetPath, (Join-Path $tempRoot 'identity-original.tmp'))
    [IO.File]::WriteAllText($targetPath, 'new-data')
    [IO.File]::SetCreationTimeUtc($targetPath, [datetime]::new([long]$original.CreationTicks, [DateTimeKind]::Utc))
    [IO.File]::SetLastWriteTimeUtc($targetPath, [datetime]::new([long]$original.LastWriteTicks, [DateTimeKind]::Utc))
    $applied = Invoke-CleanupPlan -Path $filePath -JournalDirectory $actionJournals -Apply -Confirm:$false
    Assert ($applied.deleted -eq 0 -and $applied.skipped -eq 1 -and [IO.File]::ReadAllText($targetPath) -eq 'new-data') 'Replacement file was removed.'
}
Test 'Cleanup rejects expiration, wrong target, arbitrary roots and duplicates' {
    $candidate = New-CleanupPlan
    & $cleanupModule { param($Plan) Assert-CleanupPlan $Plan } $candidate
    $candidate.userSid = 'wrong-user'
    Expect-Throw { & $cleanupModule { param($Plan) Assert-CleanupPlan $Plan } $candidate }
    $candidate = New-CleanupPlan; $candidate.expiresAtUtc = [datetime]::UtcNow.AddMinutes(-1).ToString('o')
    Expect-Throw { & $cleanupModule { param($Plan) Assert-CleanupPlan $Plan } $candidate }
    $candidate = New-CleanupPlan; $candidate.items[0].root = $actionRoot
    Expect-Throw { & $cleanupModule { param($Plan) Assert-CleanupPlan $Plan } $candidate }
    $candidate = New-CleanupPlan; $candidate.items = @($candidate.items[0],$candidate.items[0]); $candidate.candidateBytes *= 2
    Expect-Throw { & $cleanupModule { param($Plan) Assert-CleanupPlan $Plan } $candidate }
}
Test 'Cleanup byte and entry budgets are enforced' {
    $bounded = New-CleanupPlan -MaxBytes 1 -MaxEntries 100
    Assert ($bounded.candidateBytes -le 1 -and $bounded.limited) 'Byte budget exceeded.'
    $bounded = New-CleanupPlan -MaxEntries 1
    Assert ($bounded.visitedEntries -eq 1 -and $bounded.limited) 'Entry budget exceeded.'
}
Test 'No deletion when the audit destination cannot be created' {
    $candidate = New-CleanupPlan
    $filePath = Save-FixturePlan $candidate
    $blockedJournal = Join-Path $actionRoot 'journal-is-a-file'
    [IO.File]::WriteAllText($blockedJournal,'blocked')
    Expect-Throw { Invoke-CleanupPlan -Path $filePath -JournalDirectory $blockedJournal -Apply -Confirm:$false }
    Assert ([IO.File]::Exists($candidate.items[0].file.Path)) 'File removed without journal.'
    Expect-Throw { Invoke-CleanupPlan -Path $filePath -JournalDirectory $tempRoot -Apply -Confirm:$false }
}
Test 'Native deletion refuses an ancestor replaced with a junction' {
    $victim = New-OldFixtureFile 'swap/victim.tmp'
    $candidate = New-CleanupPlan
    $candidate.items = @($candidate.items | Where-Object { $_.file.Path -eq $victim }); $candidate.candidateBytes = 8
    $filePath = Save-FixturePlan $candidate
    $swapDirectory = Join-Path $tempRoot 'swap'
    $outsideDirectory = Join-Path $actionRoot 'outside'
    $null = [IO.Directory]::CreateDirectory($outsideDirectory)
    $outsideFile = Join-Path $outsideDirectory 'victim.tmp'
    [IO.File]::WriteAllText($outsideFile, 'keep-me')
    [IO.File]::Delete($victim)
    [IO.Directory]::Delete($swapDirectory)
    $null = New-Item -ItemType Junction -Path $swapDirectory -Target $outsideDirectory
    try {
        $applied = Invoke-CleanupPlan -Path $filePath -JournalDirectory $actionJournals -Apply -Confirm:$false
        Assert ($applied.deleted -eq 0 -and $applied.skipped -eq 1) 'Followed substituted junction.'
        Assert ([IO.File]::ReadAllText($outsideFile) -eq 'keep-me') 'Outside file was modified.'
        $linkedPlan = New-CleanupPlan
        Assert (@($linkedPlan.items | Where-Object { $_.file.Path -eq $victim }).Count -eq 0) 'Planner followed junction.'
    } finally { [IO.Directory]::Delete($swapDirectory) }
}
Test 'Maintenance catalog rejects arbitrary commands and disk arguments' {
    Expect-Throw { Get-MaintenanceAction -Action 'Invoke-Expression' }
    Expect-Throw { Get-MaintenanceAction -Action OptimizeVolume -DriveLetter 'C; whoami' }
    Expect-Throw { Get-MaintenanceAction -Action CleanComponentStore -DriveLetter C }
    $definition = Get-MaintenanceAction -Action CleanComponentStore
    Assert ($definition.arguments -contains '/StartComponentCleanup' -and $definition.arguments -notcontains '/ResetBase') 'Unexpected DISM switches.'
    $definition = Get-MaintenanceAction -Action OptimizeVolume -DriveLetter C
    Assert (-not $definition.parameters.ContainsKey('Defrag')) 'Forced defrag instead of automatic selection.'
}
Test 'Maintenance preview and WhatIf never invoke system commands' {
    $maintenanceModule = Get-Module Maintenance
    & $maintenanceModule { function script:Invoke-MaintenanceCommand { throw 'Unexpected system command.' } }
    foreach ($action in @('AnalyzeComponentStore','CleanComponentStore','AnalyzeVolume','OptimizeVolume','FlushDns','VerifySystemFiles')) {
        $arguments = @{ Action = $action; JournalDirectory = (Join-Path $actionRoot 'preview-only') }
        if ($action -in @('AnalyzeVolume','OptimizeVolume')) { $arguments.DriveLetter = 'C' }
        Assert ((Invoke-WindowsMaintenance @arguments).mode -eq 'preview') 'Missing maintenance preview.'
        Invoke-WindowsMaintenance @arguments -Apply -WhatIf
    }
    Assert (-not [IO.Directory]::Exists((Join-Path $actionRoot 'preview-only'))) 'Preview wrote files.'
}
Test 'Maintenance logs failures and restart-required code without running commands' {
    $maintenanceModule = Get-Module Maintenance
    & $maintenanceModule {
        function script:Test-MaintenanceAdministrator { return $true }
        function script:Invoke-MaintenanceCommand { [pscustomobject]@{ exitCode = 3010; rebootRequired = $true } }
    }
    $record = Invoke-WindowsMaintenance -Action CleanComponentStore -JournalDirectory $actionJournals -Apply -Confirm:$false
    Assert ($record.state -eq 'completed' -and $record.result.rebootRequired) 'Restart status was lost.'
    & $maintenanceModule { function script:Invoke-MaintenanceCommand { throw 'synthetic failure' } }
    Expect-Throw { Invoke-WindowsMaintenance -Action FlushDns -JournalDirectory $actionJournals -Apply -Confirm:$false }
    $records = @(Get-ChildItem -LiteralPath $actionJournals -Filter result.json -Recurse -File | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    Assert (@($records | Where-Object state -eq 'failed').Count -eq 1) 'Failure was not journaled.'
}
function New-ComparisonFixture([string] $Date, [long] $FreeMemory, [long] $FreeDisk, [double] $Cpu) {
    [pscustomobject]@{ schemaVersion = 1; computerName = 'fixture-pc'; userSid = 'fixture-user'; finishedAtUtc = $Date
        options = [pscustomobject]@{ sampleSeconds = 2 }; sections = [pscustomobject]@{
            system = [pscustomobject]@{ status = 'ok'; items = @([pscustomobject]@{ freeMemoryBytes = $FreeMemory; totalMemoryBytes = 1000 }) }
            processes = [pscustomobject]@{ status = 'ok'; items = @([pscustomobject]@{ id = 42; cpuPercent = $Cpu }) }
            disks = [pscustomobject]@{ status = 'ok'; items = @([pscustomobject]@{ DeviceID = 'C:'; Size = 1000; FreeSpace = $FreeDisk }) }
        } }
}
Test 'Snapshot comparison computes signed deltas and binds target' {
    $beforeFixture = New-ComparisonFixture '2026-01-01T00:00:00Z' 100 100 30
    $afterFixture = New-ComparisonFixture '2026-01-01T00:01:00Z' 250 300 10
    $comparison = Compare-SystemSnapshots -Before $beforeFixture -After $afterFixture
    Assert ($comparison.memory.freeBytesDelta -eq 150 -and $comparison.disks[0].freeBytesDelta -eq 200 -and $comparison.cpu.percentagePointDelta -eq -20) 'Comparison deltas incorrect.'
    $afterFixture.userSid = 'another-user'
    Expect-Throw { Compare-SystemSnapshots -Before $beforeFixture -After $afterFixture }
    Expect-Throw { Compare-SystemSnapshots -Before $beforeFixture -After $beforeFixture }
}
Test 'Snapshot comparison preserves missing CPU instead of claiming zero' {
    $beforeFixture = New-ComparisonFixture '2026-01-01T00:00:00Z' 100 100 30
    $afterFixture = New-ComparisonFixture '2026-01-01T00:01:00Z' 250 300 10
    $afterFixture.sections.processes.items = @(); $afterFixture.sections.processes.status = 'error'
    $afterFixture.sections.system.items[0].freeMemoryBytes = $null
    $comparison = Compare-SystemSnapshots -Before $beforeFixture -After $afterFixture
    Assert ($null -eq $comparison.cpu -and $null -eq $comparison.memory -and $comparison.warnings.Count -ge 3) 'Missing CPU/memory was presented as zero.'
}
