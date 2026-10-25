#requires -Version 5.1
Set-StrictMode -Version Latest
$script:RunSubkey = 'Software\Microsoft\Windows\CurrentVersion\Run'

function Get-StartupIdentity {
    [pscustomobject]@{ computerName = $env:COMPUTERNAME
        userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
}

function Get-RunEntry {
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Name)
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RunSubkey, $false)
    if ($null -eq $key) { throw 'Current-user Run key does not exist.' }
    try {
        if ($key.GetValueNames() -notcontains $Name) { throw ('Startup value not found: ' + $Name) }
        $kind = $key.GetValueKind($Name).ToString()
        if ($kind -notin @('String','ExpandString')) { throw 'Only String/ExpandString values are supported.' }
        $value = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        [pscustomobject]@{ name = $Name; value = [string]$value; kind = $kind }
    } finally { $key.Close() }
}

function Assert-StartupBackup {
    param([Parameter(Mandatory)] $Backup, [Parameter(Mandatory)] $Identity)
    foreach ($property in @('schemaVersion','action','computerName','userSid','registrySubkey','entry','createdAtUtc')) {
        if ($Backup.PSObject.Properties.Name -notcontains $property) { throw ('Missing backup property: ' + $property) }
    }
    if ($Backup.schemaVersion -ne 1 -or $Backup.action -ne 'disable-hkcu-run' -or $Backup.registrySubkey -cne $script:RunSubkey) { throw 'Unsupported startup backup.' }
    if ($Backup.computerName -ne $Identity.computerName -or $Backup.userSid -ne $Identity.userSid) { throw 'Backup belongs to another computer or user SID.' }
    foreach ($property in @('name','value','kind')) {
        if ($Backup.entry.PSObject.Properties.Name -notcontains $property) { throw ('Missing entry property: ' + $property) }
    }
    if ($Backup.entry.name -isnot [string] -or [string]::IsNullOrWhiteSpace($Backup.entry.name) -or
        $Backup.entry.value -isnot [string] -or $Backup.entry.kind -notin @('String','ExpandString')) { throw 'Invalid startup value in backup.' }
}

function Disable-RunEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Name,
        [Parameter(Mandatory)][string] $BackupDirectory,
        [switch] $Apply
    )
    $entry = Get-RunEntry $Name
    if (-not $Apply) {
        return [pscustomobject]@{ mode = 'preview'; target = ('HKCU\' + $script:RunSubkey); entry = $entry
            effect = 'Stops this Run value launching on future sign-in. Does not stop a running process.' }
    }
    if (-not $PSCmdlet.ShouldProcess(('HKCU Run: ' + $Name), 'Back up and disable startup value')) { return }
    $identity = Get-StartupIdentity
    $backup = [pscustomobject]@{ schemaVersion = 1; action = 'disable-hkcu-run'
        computerName = $identity.computerName; userSid = $identity.userSid
        registrySubkey = $script:RunSubkey; createdAtUtc = [datetime]::UtcNow.ToString('o'); entry = $entry }
    $backupPath = Join-Path $BackupDirectory ('startup-' + [guid]::NewGuid().ToString('N') + '.json')
    # Write-NewJson uses CreateNew; failure to persist the backup prevents the mutation.
    $saved = Write-NewJson -Value $backup -Path $backupPath
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RunSubkey, $true)
    if ($null -eq $key) { throw ('Run key disappeared. Backup: ' + $saved) }
    try {
        $current = Get-RunEntry $Name
        if ($current.kind -cne $entry.kind -or $current.value -cne $entry.value) { throw ('Value changed after preview. Backup: ' + $saved) }
        $key.DeleteValue($Name, $true)
        $key.Flush()
        if ($key.GetValueNames() -contains $Name) { throw ('Disable verification failed. Backup: ' + $saved) }
    } finally { $key.Close() }
    [pscustomobject]@{ mode = 'disabled'; name = $Name; backupPath = $saved }
}

function Restore-RunEntry {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $Path, [switch] $Apply)
    $backup = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json
    Assert-StartupBackup -Backup $backup -Identity (Get-StartupIdentity)
    if (-not $Apply) { return [pscustomobject]@{ mode = 'preview'; entry = $backup.entry; target = ('HKCU\' + $script:RunSubkey) } }
    if (-not $PSCmdlet.ShouldProcess(('HKCU Run: ' + $backup.entry.name), 'Restore startup value without overwriting')) { return }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RunSubkey, $true)
    if ($null -eq $key) { throw 'Run key missing; no automatic key creation. Inspect current system state.' }
    try {
        if ($key.GetValueNames() -contains $backup.entry.name) { throw 'Value already exists; refusing overwrite.' }
        $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind], $backup.entry.kind, $false)
        $key.SetValue($backup.entry.name, $backup.entry.value, $kind)
        $key.Flush()
        $restored = Get-RunEntry $backup.entry.name
        if ($restored.kind -cne $backup.entry.kind -or $restored.value -cne $backup.entry.value) { throw 'Restore verification failed.' }
    } finally { $key.Close() }
    [pscustomobject]@{ mode = 'restored'; name = $backup.entry.name; backupPath = [IO.Path]::GetFullPath($Path) }
}

Export-ModuleMember -Function Disable-RunEntry,Restore-RunEntry,Assert-StartupBackup
