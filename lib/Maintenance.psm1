#requires -Version 5.1
Set-StrictMode -Version Latest

function Get-MaintenanceAction {
    param(
        [Parameter(Mandatory)][ValidateSet('AnalyzeComponentStore','CleanComponentStore','AnalyzeVolume','OptimizeVolume','FlushDns','VerifySystemFiles')][string] $Action,
        [string] $DriveLetter
    )
    $volumeAction = $Action -in @('AnalyzeVolume','OptimizeVolume')
    if ($volumeAction -and $DriveLetter -notmatch '^[A-Za-z]$') { throw 'Provide one drive letter, e.g. C, for volume actions.' }
    if (-not $volumeAction -and $DriveLetter) { throw 'DriveLetter is only valid for volume actions.' }
    $systemDirectory = [Environment]::SystemDirectory
    $arguments = @(); $command = $null; $parameters = @{}; $risk = ''; $requiresAdmin = $true; $changes = $false
    switch ($Action) {
        AnalyzeComponentStore {
            $command = Join-Path $systemDirectory 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/AnalyzeComponentStore','/NoRestart')
            $risk = 'Analyzes the component store; may take several minutes.'
        }
        CleanComponentStore {
            $command = Join-Path $systemDirectory 'dism.exe'; $arguments = @('/Online','/Cleanup-Image','/StartComponentCleanup','/NoRestart')
            $changes = $true
            $risk = 'Removes superseded Windows components without the scheduled-task grace period. No application-level undo; no ResetBase and no automatic reboot.'
        }
        AnalyzeVolume {
            $command = 'Storage\Optimize-Volume'; $parameters = @{ DriveLetter = [char]$DriveLetter.ToUpperInvariant(); Analyze = $true }
            $risk = 'Analyzes one volume; I/O load may temporarily rise.'
        }
        OptimizeVolume {
            $command = 'Storage\Optimize-Volume'; $parameters = @{ DriveLetter = [char]$DriveLetter.ToUpperInvariant() }
            $changes = $true
            $risk = 'Windows selects an operation appropriate to the volume. I/O load can be high; no automatic undo. This does not guarantee a speed improvement.'
        }
        FlushDns {
            $command = 'DnsClient\Clear-DnsClientCache'; $requiresAdmin = $false; $changes = $true
            $risk = 'Clears the local DNS resolver cache only. Entries are rebuilt; initial lookups may be slower. DNS configuration and network adapters are unchanged.'
        }
        VerifySystemFiles {
            $command = Join-Path $systemDirectory 'sfc.exe'; $arguments = @('/verifyonly')
            $risk = 'Checks protected system files without repairing them. Read the native result/log; exit code alone is not a diagnosis.'
        }
    }
    [pscustomobject]@{ action = $Action; command = $command; arguments = $arguments; parameters = $parameters
        requiresAdministrator = $requiresAdmin; changesSystem = $changes; effectAndRisk = $risk }
}

function Test-MaintenanceAdministrator {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-MaintenanceCommand {
    param($Definition, [string] $LogDirectory)
    if ($Definition.command.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        # Native argument vectors are fixed by the catalog, never supplied by a report or shell string.
        $stdout = Join-Path $LogDirectory 'stdout.txt'; $stderr = Join-Path $LogDirectory 'stderr.txt'
        $process = Start-Process -FilePath $Definition.command -ArgumentList $Definition.arguments -PassThru -Wait -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -ErrorAction Stop
        return [pscustomobject]@{ exitCode = $process.ExitCode; rebootRequired = ($process.ExitCode -eq 3010)
            stdoutPath = $stdout; stderrPath = $stderr; outputPath = $null }
    }
    $parameters = $Definition.parameters
    $output = Join-Path $LogDirectory 'output.txt'
    & $Definition.command @parameters -ErrorAction Stop -Verbose 4>&1 | Out-File -LiteralPath $output -Encoding UTF8 -ErrorAction Stop
    [pscustomobject]@{ exitCode = $null; rebootRequired = $false; stdoutPath = $null; stderrPath = $null; outputPath = $output }
}

function Invoke-WindowsMaintenance {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateSet('AnalyzeComponentStore','CleanComponentStore','AnalyzeVolume','OptimizeVolume','FlushDns','VerifySystemFiles')][string] $Action,
        [string] $DriveLetter,
        [Parameter(Mandatory)][string] $JournalDirectory,
        [switch] $Apply
    )
    Assert-WindowsHost
    $definition = Get-MaintenanceAction -Action $Action -DriveLetter $DriveLetter
    if (-not $Apply) { return [pscustomobject]@{ mode = 'preview'; operation = $definition } }
    if (-not $PSCmdlet.ShouldProcess(($Action + ' ' + $DriveLetter), $definition.effectAndRisk)) { return }
    if ($definition.requiresAdministrator -and -not (Test-MaintenanceAdministrator)) { throw 'This action requires an already elevated PowerShell session. No automatic elevation.' }
    $directory = Join-Path ([IO.Path]::GetFullPath($JournalDirectory)) ('maintenance-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($directory)
    $pending = [pscustomobject]@{ schemaVersion = 1; atUtc = [datetime]::UtcNow.ToString('o'); computerName = $env:COMPUTERNAME
        userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value; operation = $definition; state = 'started' }
    $null = Write-NewJson -Value $pending -Path (Join-Path $directory 'request.json')
    $result = $null; $failure = $null
    try {
        $result = Invoke-MaintenanceCommand $definition $directory
        if ($null -ne $result.exitCode -and $result.exitCode -notin @(0,3010)) { $failure = 'Native command returned exit code ' + $result.exitCode }
    } catch { $failure = $_.Exception.Message }
    $state = $(if ($null -eq $failure) { 'completed' } else { 'failed' })
    $record = [pscustomobject]@{ mode = 'applied'; action = $Action; state = $state; atUtc = [datetime]::UtcNow.ToString('o')
        result = $result; error = $failure; journalDirectory = $directory }
    $null = Write-NewJson -Value $record -Path (Join-Path $directory 'result.json')
    if ($null -ne $failure) { throw ('Maintenance failed: {0}. Logs: {1}' -f $failure,$directory) }
    $record
}

Export-ModuleMember -Function Get-MaintenanceAction,Invoke-WindowsMaintenance
