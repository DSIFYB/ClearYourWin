#requires -Version 5.1
Set-StrictMode -Version Latest

function Initialize-CleanupNative {
    Assert-WindowsHost
    if (-not ('ClearYourWin.CleanupNative' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'CleanupNative.cs') -ErrorAction Stop
    }
}

function Get-CleanupRoots {
    param([ValidateSet('UserTemp','WindowsTemp','Both')][string] $Scope)
    # Do not trust TEMP/TMP environment overrides as authorization to delete arbitrary directories.
    if ($Scope -in @('UserTemp','Both')) { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp' }
    if ($Scope -in @('WindowsTemp','Both')) { Join-Path ([Environment]::GetFolderPath('Windows')) 'Temp' }
}

function Get-CleanupIdentity {
    [pscustomobject]@{ computerName = $env:COMPUTERNAME; userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
}

function ConvertTo-CleanupUtc {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    return [datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Test-CleanupExtension {
    param([string] $Path)
    # Leave runnable files as evidence for separate investigation, not as automatic cleanup targets.
    return [IO.Path]::GetExtension($Path) -notmatch '^\.(exe|dll|scr|com|msi|msix|ps1|psm1|bat|cmd|vbs|js|sys|lnk)$'
}

function New-CleanupPlan {
    [CmdletBinding()]
    param(
        [ValidateSet('UserTemp','WindowsTemp','Both')][string] $Scope = 'UserTemp',
        [ValidateRange(7,365)][int] $MinAgeDays = 7,
        [ValidateRange(1,5000)][int] $MaxFiles = 1000,
        [ValidateRange(1,10737418240)][long] $MaxBytes = 2GB,
        [ValidateRange(1,100000)][int] $MaxEntries = 10000,
        [ValidateRange(1,120)][int] $ScanSeconds = 10
    )
    Initialize-CleanupNative
    $now = [datetime]::UtcNow
    $cutoff = $now.AddDays(-$MinAgeDays).Ticks
    $items = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $roots = @(Get-CleanupRoots $Scope | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    $stack = [Collections.Generic.Stack[object]]::new()
    foreach ($root in $roots) { $stack.Push(@{ path = $root; root = $root; depth = 0 }) }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $visited = 0; $total = [long]0; $skipped = 0; $limited = $false
    while ($stack.Count -gt 0 -and -not $limited) {
        $directory = $stack.Pop()
        $enumerator = $null
        try {
            # Reject links before traversal as well as inside the native per-file verifier.
            $ancestor = [IO.DirectoryInfo]::new($directory.path)
            while ($null -ne $ancestor) {
                if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked directory skipped.' }
                $ancestor = $ancestor.Parent
            }
            $enumerator = [IO.Directory]::EnumerateFileSystemEntries($directory.path).GetEnumerator()
            while ($true) {
                if ($visited -ge $MaxEntries -or $clock.Elapsed.TotalSeconds -ge $ScanSeconds -or $items.Count -ge $MaxFiles) { $limited = $true; break }
                if (-not $enumerator.MoveNext()) { break }
                $visited++
                $path = $enumerator.Current
                try {
                    $attributes = [IO.File]::GetAttributes($path)
                    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $skipped++; continue }
                    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                        if ($directory.depth -ge 32) { $limited = $true; break }
                        $stack.Push(@{ path = $path; root = $directory.root; depth = $directory.depth + 1 }); continue
                    }
                    if (-not (Test-CleanupExtension $path)) { $skipped++; continue }
                    $file = [IO.FileInfo]::new($path)
                    if ($file.LastWriteTimeUtc.Ticks -ge $cutoff -or $file.CreationTimeUtc.Ticks -ge $cutoff) { continue }
                    $verified = [ClearYourWin.CleanupNative]::Inspect($directory.root, $path, $cutoff)
                    if ($verified.Length -gt ($MaxBytes - $total)) { $limited = $true; continue }
                    $items.Add([pscustomobject]@{ root = $directory.root; file = $verified })
                    $total += $verified.Length
                } catch { $skipped++; if ($errors.Count -lt 30) { $errors.Add(('{0}: {1}' -f $path, $_.Exception.Message)) } }
            }
        } catch { if ($errors.Count -lt 30) { $errors.Add(('{0}: {1}' -f $directory.path, $_.Exception.Message)) } }
        finally { if ($null -ne $enumerator -and $enumerator -is [IDisposable]) { $enumerator.Dispose() } }
    }
    $identity = Get-CleanupIdentity
    [pscustomobject]@{ schemaVersion = 1; kind = 'temp-cleanup'; planId = [guid]::NewGuid().ToString('N')
        computerName = $identity.computerName; userSid = $identity.userSid; scope = $Scope
        createdAtUtc = $now.ToString('o'); expiresAtUtc = $now.AddHours(4).ToString('o')
        minAgeDays = $MinAgeDays; maxBytes = $MaxBytes; candidateBytes = $total
        roots = $roots; items = @($items.ToArray()); visitedEntries = $visited; skipped = $skipped
        limited = $limited; errors = @($errors.ToArray()); complete = (-not $limited -and $errors.Count -eq 0 -and $skipped -eq 0)
        warning = 'Permanent deletion, no automatic undo. Only listed unchanged files will be attempted.' }
}

function Assert-CleanupPlan {
    param([Parameter(Mandatory)] $Plan)
    $identity = Get-CleanupIdentity
    if ($Plan.schemaVersion -ne 1 -or $Plan.kind -cne 'temp-cleanup' -or
        $Plan.computerName -ne $identity.computerName -or $Plan.userSid -ne $identity.userSid) { throw 'Unsupported plan or wrong computer/user.' }
    if ($Plan.scope -notin @('UserTemp','WindowsTemp','Both')) { throw 'Invalid cleanup scope.' }
    $created = ConvertTo-CleanupUtc $Plan.createdAtUtc
    $expires = ConvertTo-CleanupUtc $Plan.expiresAtUtc
    $now = [datetime]::UtcNow
    if ($created -gt $now.AddMinutes(5) -or $created -lt $now.AddHours(-4) -or $expires -le $now -or $expires -gt $created.AddHours(4)) { throw 'Cleanup plan expired or invalid dates.' }
    if ($Plan.minAgeDays -lt 7 -or $Plan.minAgeDays -gt 365 -or $Plan.maxBytes -lt 1 -or $Plan.maxBytes -gt 10GB -or @($Plan.items).Count -gt 5000) { throw 'Invalid cleanup budget.' }
    $allowed = @(Get-CleanupRoots $Plan.scope | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $total = [long]0
    foreach ($item in $Plan.items) {
        $root = [IO.Path]::GetFullPath($item.root).TrimEnd('\')
        $path = [IO.Path]::GetFullPath($item.file.Path)
        if ($allowed -notcontains $root -or -not $path.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-CleanupExtension $path) -or -not $seen.Add($path)) { throw 'Unapproved or duplicate cleanup path.' }
        if ($item.file.Length -lt 0 -or $item.file.Length -gt ($Plan.maxBytes - $total) -or
            $item.file.FileId -notmatch '^[0-9A-F]{8}:[0-9A-F]{16}$') { throw 'Invalid cleanup file metadata.' }
        $cutoff = $created.AddDays(-[int]$Plan.minAgeDays).Ticks
        if ([long]$item.file.LastWriteTicks -ge $cutoff -or [long]$item.file.CreationTicks -ge $cutoff) { throw 'Plan contains a recent file.' }
        $total += [long]$item.file.Length
    }
    if ($total -ne $Plan.candidateBytes) { throw 'Cleanup byte totals do not match.' }
}

function Write-AuditEvent {
    param([IO.StreamWriter] $Writer, $Event)
    $Writer.WriteLine(($Event | ConvertTo-Json -Depth 12 -Compress)); $Writer.Flush()
    $Writer.BaseStream.Flush($true)
}

function Invoke-CleanupPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $JournalDirectory, [switch] $Apply)
    $plan = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    Assert-CleanupPlan $plan
    if (-not $Apply) { return [pscustomobject]@{ mode = 'preview'; planId = $plan.planId; files = @($plan.items).Count; bytes = $plan.candidateBytes; items = $plan.items; warning = 'Permanent deletion, no automatic undo.' } }
    if (-not $PSCmdlet.ShouldProcess(('{0} TEMP files, up to {1} bytes' -f @($plan.items).Count,$plan.candidateBytes), 'Permanently delete the approved unchanged files')) { return }
    Initialize-CleanupNative
    $journalParent = [IO.Path]::GetFullPath($JournalDirectory).TrimEnd('\')
    foreach ($root in (Get-CleanupRoots $plan.scope)) {
        $normalized = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($journalParent -eq $normalized -or $journalParent.StartsWith($normalized + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Journal must be outside cleanup roots.' }
    }
    $null = [IO.Directory]::CreateDirectory($journalParent)
    $journal = Join-Path $journalParent ('cleanup-' + [guid]::NewGuid().ToString('N') + '.jsonl')
    $stream = [IO.File]::Open($journal, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $deleted = 0; $deletedBytes = [long]0; $skipped = 0
    try {
        Write-AuditEvent $writer @{ event = 'begin'; atUtc = [datetime]::UtcNow.ToString('o'); plan = $plan }
        foreach ($item in $plan.items) {
            Write-AuditEvent $writer @{ event = 'intent'; path = $item.file.Path }
            $outcome = $null
            try {
                $expected = [ClearYourWin.CleanupFile]::new()
                foreach ($property in @('Path','Length','FileId','LastWriteTicks','CreationTicks')) { $expected.$property = $item.file.$property }
                # Preserve the original cutoff; a file cannot age into an approved plan later.
                $cutoff = (ConvertTo-CleanupUtc $plan.createdAtUtc).AddDays(-[int]$plan.minAgeDays).Ticks
                $removed = [ClearYourWin.CleanupNative]::DeleteVerified($item.root, $expected, $cutoff)
                $deleted++; $deletedBytes += $removed.Length
                $outcome = @{ event = 'deleted'; path = $item.file.Path; bytes = $removed.Length }
            } catch { $skipped++; $outcome = @{ event = 'skipped'; path = $item.file.Path; reason = $_.Exception.Message } }
            # A journal write failure aborts the operation instead of deleting more files.
            Write-AuditEvent $writer $outcome
        }
        Write-AuditEvent $writer @{ event = 'end'; deleted = $deleted; deletedBytes = $deletedBytes; skipped = $skipped }
    } finally { $writer.Dispose() }
    [pscustomobject]@{ mode = 'applied'; deleted = $deleted; deletedBytes = $deletedBytes; skipped = $skipped; journalPath = $journal }
}

Export-ModuleMember -Function New-CleanupPlan,Invoke-CleanupPlan
