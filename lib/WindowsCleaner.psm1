#requires -Version 5.1
Set-StrictMode -Version Latest

function Assert-WindowsHost {
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
        throw 'Use 64-bit PowerShell on Windows.'
    }
}

function Write-NewJson {
    param([Parameter(Mandatory)] $Value, [Parameter(Mandatory)][string] $Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 32))
    $stream = [IO.File]::Open($fullPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    return $fullPath
}

function Invoke-SnapshotSection {
    param([scriptblock] $Collect)
    $issues = [Collections.Generic.List[string]]::new()
    $items = @()
    $status = 'ok'
    try {
        $items = @(& $Collect $issues)
        if ($issues.Count) { $status = 'partial' }
    } catch {
        $issues.Add($_.Exception.Message)
        $status = 'error'
    }
    [pscustomobject]@{ status = $status; items = @($items); errors = @($issues.ToArray()) }
}

function Get-DefaultScanRoots {
    @($env:TEMP; (Join-Path $env:SystemRoot 'Temp')) | Where-Object { $_ } | Select-Object -Unique
}

function Test-ReparseAncestor {
    param([string] $Path)
    $current = [IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path))
    while ($null -ne $current) {
        if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        $current = $current.Parent
    }
    return $false
}

function Get-DiskScan {
    param(
        [Parameter(Mandatory)][string[]] $Root,
        [ValidateRange(1,1000000)][int] $MaxEntries = 10000,
        [ValidateRange(1,120)][int] $Seconds = 10,
        [datetime] $NowUtc = [datetime]::UtcNow
    )
    foreach ($rootPath in ($Root | Select-Object -Unique)) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $issues = [Collections.Generic.List[string]]::new()
        $old = [Collections.Generic.List[object]]::new()
        $executables = [Collections.Generic.List[object]]::new()
        $pending = [Collections.Generic.Stack[object]]::new()
        $visited = 0; $fileCount = 0; $bytes = [long]0; $oldBytes = [long]0
        $oldCount = 0; $execCount = 0; $skippedLinks = 0; $limited = $false
        $fullRoot = $rootPath
        $isTemp = $false
        try {
            $fullRoot = [IO.Path]::GetFullPath($rootPath).TrimEnd('\')
            # Preserve drive roots; C: means current directory on the drive, not C:\.
            if ($fullRoot -match '^[A-Za-z]:$') { $fullRoot += '\' }
            if (-not [IO.Directory]::Exists($fullRoot)) { throw 'Directory missing or inaccessible.' }
            if (Test-ReparseAncestor $fullRoot) { throw 'Root or ancestor is a reparse point; skipped.' }
            $isTemp = @((Get-DefaultScanRoots) | Where-Object {
                [string]::Equals([IO.Path]::GetFullPath($_).TrimEnd('\'), $fullRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            $pending.Push(@{ path = $fullRoot; depth = 0 })
            while ($pending.Count -gt 0 -and -not $limited) {
                if ($clock.Elapsed.TotalSeconds -ge $Seconds -or $visited -ge $MaxEntries) { $limited = $true; break }
                $directory = $pending.Pop()
                $enumerator = $null
                try {
                    if (Test-ReparseAncestor $directory.path) { $skippedLinks++; continue }
                    $enumerator = [IO.Directory]::EnumerateFileSystemEntries($directory.path).GetEnumerator()
                    while ($true) {
                        if ($clock.Elapsed.TotalSeconds -ge $Seconds -or $visited -ge $MaxEntries) { $limited = $true; break }
                        if (-not $enumerator.MoveNext()) { break }
                        $entryPath = $enumerator.Current
                        $visited++
                        try {
                            $attributes = [IO.File]::GetAttributes($entryPath)
                            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $skippedLinks++; continue }
                            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                                if ($directory.depth -ge 32) { $limited = $true; continue }
                                $pending.Push(@{ path = $entryPath; depth = $directory.depth + 1 })
                                continue
                            }
                            $file = [IO.FileInfo]::new($entryPath)
                            $fileBytes = $file.Length
                            $fileCount++; $bytes += $fileBytes
                            if ($isTemp -and $file.LastWriteTimeUtc -lt $NowUtc.AddDays(-7)) {
                                $oldBytes += $fileBytes; $oldCount++
                                if ($old.Count -lt 100) { $old.Add([pscustomobject]@{ path = $entryPath; bytes = $fileBytes; lastWriteUtc = $file.LastWriteTimeUtc.ToString('o') }) }
                            }
                            if ($file.Extension -match '^\.(exe|dll|scr|com|msi|ps1|bat|cmd|vbs|js)$') {
                                $execCount++
                                if ($executables.Count -lt 100) { $executables.Add([pscustomobject]@{ path = $entryPath; bytes = $fileBytes }) }
                            }
                        } catch { if ($issues.Count -lt 20) { $issues.Add(('{0}: {1}' -f $entryPath, $_.Exception.Message)) } }
                    }
                } catch { if ($issues.Count -lt 20) { $issues.Add(('{0}: {1}' -f $directory.path, $_.Exception.Message)) } }
                finally { if ($null -ne $enumerator -and $enumerator -is [IDisposable]) { $enumerator.Dispose() } }
            }
        } catch { $issues.Add($_.Exception.Message) }
        [pscustomobject]@{
            root = $fullRoot; isDefaultTemp = $isTemp; visitedEntries = $visited; fileCount = $fileCount
            scannedBytes = $bytes; oldTempBytes = $oldBytes; oldTempFileCount = $oldCount
            oldTempExamples = @($old.ToArray()); executableCount = $execCount
            executableExamples = @($executables.ToArray()); skippedReparsePoints = $skippedLinks
            limited = $limited; complete = (-not $limited -and $issues.Count -eq 0 -and $skippedLinks -eq 0)
            errors = @($issues.ToArray()); elapsedSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 3)
        }
    }
}

function Get-StartupInventory {
    param($Issues)
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'
    )
    foreach ($keyPath in $keys) {
        try {
            if (-not (Test-Path -LiteralPath $keyPath -ErrorAction Stop)) { continue }
            $key = Get-Item -LiteralPath $keyPath -ErrorAction Stop
            try {
                foreach ($name in $key.GetValueNames()) {
                    [pscustomobject]@{ source = 'registry'; location = $keyPath; name = $name
                        command = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        kind = $key.GetValueKind($name).ToString() }
                }
            } finally { $key.Close() }
        } catch { $Issues.Add(('{0}: {1}' -f $keyPath, $_.Exception.Message)) }
    }
    foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        try {
            if (-not $folder -or -not (Test-Path -LiteralPath $folder -ErrorAction Stop)) { continue }
            Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{ source = 'folder'; location = $folder; name = $_.Name; command = $_.FullName; kind = 'file' }
            }
        } catch { $Issues.Add($_.Exception.Message) }
    }
    try {
        foreach ($task in (Get-ScheduledTask -ErrorAction Stop)) {
            $bootTriggers = @($task.Triggers | Where-Object { Test-StartupTrigger $_ })
            if ($bootTriggers.Count -eq 0) { continue }
            [pscustomobject]@{ source = 'task'; location = $task.TaskPath; name = $task.TaskName
                state = $task.State.ToString(); actions = @($task.Actions | Select-Object Execute,Arguments,WorkingDirectory) }
        }
    } catch { $Issues.Add(('Scheduled tasks: ' + $_.Exception.Message)) }
}

function Test-StartupTrigger {
    param($Trigger)
    # Tasks without triggers can pipe a null element under strict mode.
    return ($null -ne $Trigger -and $Trigger.CimClass.CimClassName -in @('MSFT_TaskBootTrigger','MSFT_TaskLogonTrigger'))
}

function Test-SameProcessStart {
    param([datetime] $Left, [datetime] $Right)
    # CIM dates have microsecond precision, Process.StartTime has 100 ns precision.
    $leftTicks = $Left.ToUniversalTime().Ticks
    $rightTicks = $Right.ToUniversalTime().Ticks
    return (($leftTicks - ($leftTicks % 10)) -eq ($rightTicks - ($rightTicks % 10)))
}

function Get-ApplicationInventory {
    param($Issues)
    foreach ($keyPath in @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )) {
        try {
            if (-not (Test-Path -LiteralPath $keyPath -ErrorAction Stop)) { continue }
            foreach ($entry in (Get-ChildItem -LiteralPath $keyPath -ErrorAction Stop)) {
                try {
                    $name = $entry.GetValue('DisplayName')
                    if ($name) {
                        [pscustomobject]@{ name = $name; version = $entry.GetValue('DisplayVersion')
                            publisher = $entry.GetValue('Publisher'); installLocation = $entry.GetValue('InstallLocation')
                            registryPath = $entry.Name }
                    }
                } catch { $Issues.Add($_.Exception.Message) } finally { $entry.Close() }
            }
        } catch { $Issues.Add($_.Exception.Message) }
    }
}

function Get-SystemSnapshot {
    [CmdletBinding()]
    param(
        [ValidateRange(1,10)][int] $SampleSeconds = 2,
        [switch] $IncludeThreads,
        [string[]] $ScanRoot = @(),
        [ValidateRange(1,1000000)][int] $MaxScanEntries = 10000,
        [ValidateRange(1,120)][int] $ScanSeconds = 10
    )
    Assert-WindowsHost
    $started = [datetime]::UtcNow
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    $logicalCpu = [Environment]::ProcessorCount
    $sections = [ordered]@{}
    $sections.system = Invoke-SnapshotSection {
        param($issues)
        $os = Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 15 -ErrorAction Stop
        $computer = Get-CimInstance Win32_ComputerSystem -OperationTimeoutSec 15 -ErrorAction Stop
        [pscustomobject]@{ caption = $os.Caption; version = $os.Version; build = $os.BuildNumber
            lastBootUtc = $os.LastBootUpTime.ToUniversalTime().ToString('o')
            totalMemoryBytes = [long]$os.TotalVisibleMemorySize * 1024
            freeMemoryBytes = [long]$os.FreePhysicalMemory * 1024
            logicalProcessors = $logicalCpu; manufacturer = $computer.Manufacturer; model = $computer.Model }
    }
    $sections.processes = Invoke-SnapshotSection {
        param($issues)
        $first = @{}
        $sampleClock = [Diagnostics.Stopwatch]::StartNew()
        foreach ($process in (Get-CimInstance Win32_Process -OperationTimeoutSec 15 -ErrorAction Stop)) {
            $first[[int]$process.ProcessId] = @{ created = $process.CreationDate; cpu = ([double]$process.KernelModeTime + [double]$process.UserModeTime) }
        }
        Start-Sleep -Seconds $SampleSeconds
        $second = @(Get-CimInstance Win32_Process -OperationTimeoutSec 15 -ErrorAction Stop)
        $elapsed = $sampleClock.Elapsed.TotalSeconds
        foreach ($process in $second) {
            $cpuPercent = $null
            $previous = $first[[int]$process.ProcessId]
            if ($process.ProcessId -ne 0 -and $null -ne $previous -and $previous.created -eq $process.CreationDate) {
                $delta = ([double]$process.KernelModeTime + [double]$process.UserModeTime) - $previous.cpu
                if ($delta -ge 0) { $cpuPercent = [math]::Round([math]::Min(100, 100 * $delta / 1e7 / $elapsed / $logicalCpu), 2) }
            }
            [pscustomobject]@{ id = [int]$process.ProcessId; parentId = [int]$process.ParentProcessId
                name = $process.Name; path = $process.ExecutablePath; createdAt = $process.CreationDate
                workingSetBytes = [long]$process.WorkingSetSize; privateBytes = [long]$process.PrivatePageCount
                threadCount = [int]$process.ThreadCount; cpuPercent = $cpuPercent
                sampleElapsedSeconds = [math]::Round($elapsed, 3) }
        }
    }
    $sections.threads = Invoke-SnapshotSection {
        param($issues)
        if (-not $IncludeThreads) { return }
        if ($sections.processes.status -eq 'error') { throw 'Thread collection unavailable because the process sample failed.' }
        foreach ($item in ($sections.processes.items | Where-Object { $_.id -ne 0 } | Sort-Object cpuPercent -Descending | Select-Object -First 10)) {
            try {
                $process = Get-Process -Id $item.id -ErrorAction Stop
                if ($null -ne $item.createdAt -and -not (Test-SameProcessStart $process.StartTime $item.createdAt)) {
                    throw 'Process ID reused since CPU sample.'
                }
                $count = 0
                foreach ($thread in $process.Threads) {
                    if ($count -ge 256) { $issues.Add(('Thread list limited for PID ' + $item.id)); break }
                    $count++
                    [pscustomobject]@{ processId = $item.id; threadId = $thread.Id
                        state = $thread.ThreadState.ToString(); cpuTotalSeconds = $thread.TotalProcessorTime.TotalSeconds }
                }
            } catch { $issues.Add(('PID {0}: {1}' -f $item.id, $_.Exception.Message)) }
        }
    }
    $sections.startup = Invoke-SnapshotSection { param($issues) Get-StartupInventory $issues }
    $sections.services = Invoke-SnapshotSection {
        Get-CimInstance Win32_Service -OperationTimeoutSec 15 -ErrorAction Stop |
            Select-Object Name,DisplayName,State,StartMode,PathName,ProcessId,StartName
    }
    $sections.drivers = Invoke-SnapshotSection {
        Get-CimInstance Win32_PnPSignedDriver -OperationTimeoutSec 15 -ErrorAction Stop |
            Select-Object DeviceName,DeviceID,DriverVersion,DriverDate,DriverProviderName,IsSigned,InfName
    }
    $sections.systemDrivers = Invoke-SnapshotSection {
        Get-CimInstance Win32_SystemDriver -OperationTimeoutSec 15 -ErrorAction Stop |
            Select-Object Name,DisplayName,State,StartMode,PathName,ServiceType
    }
    $sections.devices = Invoke-SnapshotSection {
        Get-CimInstance Win32_PnPEntity -OperationTimeoutSec 15 -ErrorAction Stop |
            Select-Object Name,DeviceID,PNPClass,Manufacturer,Status,ConfigManagerErrorCode,Present
    }
    $sections.disks = Invoke-SnapshotSection {
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec 15 -ErrorAction Stop |
            Select-Object DeviceID,VolumeName,FileSystem,Size,FreeSpace
    }
    $sections.applications = Invoke-SnapshotSection { param($issues) Get-ApplicationInventory $issues }
    $sections.defender = Invoke-SnapshotSection {
        Get-MpComputerStatus -ErrorAction Stop | Select-Object AntivirusEnabled,RealTimeProtectionEnabled,
            AntivirusSignatureAge,AntivirusSignatureLastUpdated,AMRunningMode
    }
    if ($ScanRoot.Count -eq 0) { $ScanRoot = @(Get-DefaultScanRoots) }
    $sections.diskScan = Invoke-SnapshotSection {
        param($issues)
        Get-DiskScan -Root $ScanRoot -MaxEntries $MaxScanEntries -Seconds $ScanSeconds | ForEach-Object {
            if (-not $_.complete) { $issues.Add(('Incomplete scan: ' + $_.root)) }
            $_
        }
    }
    [pscustomobject]@{
        schemaVersion = 1; collectorVersion = '0.1.0'; startedAtUtc = $started.ToString('o')
        finishedAtUtc = [datetime]::UtcNow.ToString('o'); computerName = $env:COMPUTERNAME
        userSid = $identity.User.Value; isAdministrator = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        options = @{ sampleSeconds = $SampleSeconds; includeThreads = [bool]$IncludeThreads
            scanRoots = @($ScanRoot); maxScanEntries = $MaxScanEntries; scanSecondsPerRoot = $ScanSeconds }
        sections = [pscustomobject]$sections
    }
}

function Get-SnapshotFindings {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Snapshot)
    if ($Snapshot.schemaVersion -ne 1) { throw 'Unsupported snapshot schemaVersion.' }
    $findings = [Collections.Generic.List[object]]::new()
    function Add-Finding($Id, $Severity, $Category, $Evidence, $Recommendation) {
        $findings.Add([pscustomobject]@{ id = $Id; severity = $Severity; category = $Category
            evidence = $Evidence; recommendation = $Recommendation })
    }
    foreach ($name in @('system','processes','threads','startup','services','drivers','systemDrivers','devices','disks','applications','defender','diskScan')) {
        if ($Snapshot.sections.PSObject.Properties.Name -notcontains $name) { throw ('Missing section: ' + $name) }
        $section = $Snapshot.sections.$name
        if ($section.status -notin @('ok','partial','error')) { throw ('Invalid section status: ' + $name) }
        if ($section.status -ne 'ok') {
            Add-Finding ('coverage.' + $name) 'info' 'coverage' (@($section.errors) -join '; ') 'Incomplete data; resolve access/limits before making conclusions.'
        }
    }
    foreach ($system in $Snapshot.sections.system.items) {
        if ($system.totalMemoryBytes -gt 0) {
            $freePercent = 100 * $system.freeMemoryBytes / $system.totalMemoryBytes
            if ($freePercent -lt 15) {
                Add-Finding 'memory.low' 'warning' 'memory' @{ freePercent = [math]::Round($freePercent, 1); freeBytes = $system.freeMemoryBytes } 'Repeat under normal workload; inspect large processes and startup. Do not force memory-cache clearing.'
            }
        }
    }
    foreach ($process in $Snapshot.sections.processes.items) {
        if ($process.id -ne 0 -and $null -ne $process.cpuPercent -and $process.cpuPercent -ge 20) {
            Add-Finding ('cpu.' + $process.id) 'warning' 'cpu' @{ id = $process.id; name = $process.name; cpuPercent = $process.cpuPercent } 'Repeat the measurement and identify the application before changing its startup or stopping it.'
        }
    }
    foreach ($disk in $Snapshot.sections.disks.items) {
        if ($disk.Size -gt 0 -and (100 * $disk.FreeSpace / $disk.Size) -lt 10) {
            Add-Finding ('disk.' + $disk.DeviceID) 'warning' 'disk' @{ drive = $disk.DeviceID; freeBytes = $disk.FreeSpace } 'Review storage usage and approved cleanup candidates. Do not remove system directories manually.'
        }
    }
    foreach ($device in $Snapshot.sections.devices.items) {
        if ($null -ne $device.ConfigManagerErrorCode -and $device.ConfigManagerErrorCode -ne 0) {
            Add-Finding ('device.' + $device.DeviceID) 'warning' 'device' @{ name = $device.Name; code = $device.ConfigManagerErrorCode } 'Inspect Device Manager and the hardware vendor documentation; do not remove the driver automatically.'
        }
    }
    foreach ($defender in $Snapshot.sections.defender.items) {
        if (-not $defender.AntivirusEnabled -or -not $defender.RealTimeProtectionEnabled) {
            Add-Finding 'protection.state' 'warning' 'protection' @{ antivirus = $defender.AntivirusEnabled; realTime = $defender.RealTimeProtectionEnabled; mode = $defender.AMRunningMode } 'Check Windows Security and any third-party antivirus. Passive Defender can be expected with another protection product.'
        }
        if ($null -ne $defender.AntivirusSignatureAge -and $defender.AntivirusSignatureAge -gt 7) {
            Add-Finding 'protection.signatures' 'warning' 'protection' @{ ageDays = $defender.AntivirusSignatureAge } 'Check the active antivirus and definition update status.'
        }
    }
    foreach ($scan in $Snapshot.sections.diskScan.items) {
        if ($scan.oldTempBytes -gt 0) {
            Add-Finding ('temp.' + $scan.root) 'info' 'cleanup' @{ root = $scan.root; candidateBytes = $scan.oldTempBytes; complete = $scan.complete } 'Review old TEMP files. Candidate bytes are not guaranteed reclaimable; no files have been deleted.'
        }
        if ($scan.isDefaultTemp -and $scan.executableCount -gt 0) {
            Add-Finding ('review.' + $scan.root) 'info' 'file-review' @{ root = $scan.root; count = $scan.executableCount; examples = $scan.executableExamples } 'TEMP executables can be legitimate installers. Inspect selected files and protection results; this is not a malware verdict.'
        }
    }
    return $findings.ToArray()
}

Export-ModuleMember -Function Assert-WindowsHost,Write-NewJson,Get-SystemSnapshot,Get-SnapshotFindings,Get-DiskScan
