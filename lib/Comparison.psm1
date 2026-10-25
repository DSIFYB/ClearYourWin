#requires -Version 5.1
Set-StrictMode -Version Latest

function Compare-SystemSnapshots {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Before, [Parameter(Mandatory)] $After)
    if ($Before.schemaVersion -ne 1 -or $After.schemaVersion -ne 1) { throw 'Unsupported snapshot version.' }
    if ([string]::IsNullOrWhiteSpace($Before.computerName) -or [string]::IsNullOrWhiteSpace($Before.userSid)) { throw 'Snapshots must identify the computer and user.' }
    if ($Before.computerName -ne $After.computerName -or $Before.userSid -ne $After.userSid) { throw 'Snapshots belong to different computers or users.' }
    if ([datetimeoffset]$Before.finishedAtUtc -ge [datetimeoffset]$After.finishedAtUtc) { throw 'After must be newer than Before.' }
    $warnings = [Collections.Generic.List[string]]::new()
    $memory = $null; $cpu = $null; $disks = [Collections.Generic.List[object]]::new()
    foreach ($name in @('system','processes','disks')) {
        if ($Before.sections.$name.status -ne 'ok' -or $After.sections.$name.status -ne 'ok') { $warnings.Add(('Incomplete section: ' + $name)) }
    }
    $firstSystem = @($Before.sections.system.items); $secondSystem = @($After.sections.system.items)
    if ($firstSystem.Count -gt 0 -and $secondSystem.Count -gt 0 -and $null -ne $firstSystem[0].freeMemoryBytes -and $null -ne $secondSystem[0].freeMemoryBytes) {
        $memory = [pscustomobject]@{ freeBytesBefore = $firstSystem[0].freeMemoryBytes; freeBytesAfter = $secondSystem[0].freeMemoryBytes
            freeBytesDelta = ([long]$secondSystem[0].freeMemoryBytes - [long]$firstSystem[0].freeMemoryBytes) }
        if ($firstSystem[0].totalMemoryBytes -ne $secondSystem[0].totalMemoryBytes) { $warnings.Add('Visible physical memory changed between measurements.') }
    } else { $warnings.Add('No comparable physical memory data; memory delta is unavailable.') }
    $firstCpu = @($Before.sections.processes.items | Where-Object { $_.id -ne 0 -and $null -ne $_.cpuPercent })
    $secondCpu = @($After.sections.processes.items | Where-Object { $_.id -ne 0 -and $null -ne $_.cpuPercent })
    if ($firstCpu.Count -gt 0 -and $secondCpu.Count -gt 0) {
        $beforeTotal = [double]($firstCpu | Measure-Object cpuPercent -Sum).Sum
        $afterTotal = [double]($secondCpu | Measure-Object cpuPercent -Sum).Sum
        $cpu = [pscustomobject]@{ sampledProcessCpuBefore = $beforeTotal; sampledProcessCpuAfter = $afterTotal
            percentagePointDelta = [math]::Round(($afterTotal - $beforeTotal),2)
            sampledProcessesBefore = $firstCpu.Count; sampledProcessesAfter = $secondCpu.Count }
    } else { $warnings.Add('No comparable process CPU samples; CPU delta is unavailable.') }
    foreach ($disk in $After.sections.disks.items) {
        $matching = @($Before.sections.disks.items | Where-Object { $_.DeviceID -eq $disk.DeviceID -and $_.Size -eq $disk.Size })
        if ($disk.Size -gt 0 -and $matching.Count -eq 1 -and $null -ne $disk.FreeSpace -and $null -ne $matching[0].FreeSpace) {
            $disks.Add([pscustomobject]@{ drive = $disk.DeviceID; freeBytesBefore = $matching[0].FreeSpace; freeBytesAfter = $disk.FreeSpace
                freeBytesDelta = ([long]$disk.FreeSpace - [long]$matching[0].FreeSpace) })
        } else { $warnings.Add(('Volume identity/size or data changed: ' + $disk.DeviceID)) }
    }
    if ($Before.options.sampleSeconds -ne $After.options.sampleSeconds) { $warnings.Add('Requested CPU sample intervals differ.') }
    [pscustomobject]@{ computerName = $After.computerName; beforeUtc = $Before.finishedAtUtc; afterUtc = $After.finishedAtUtc
        memory = $memory; cpu = $cpu; disks = @($disks.ToArray()); warnings = @($warnings.ToArray())
        note = 'Snapshot deltas do not prove causation or speed improvement. Use comparable workload and repeated measurements; summed process CPU omits new/exited/protected processes.' }
}

Export-ModuleMember -Function Compare-SystemSnapshots
