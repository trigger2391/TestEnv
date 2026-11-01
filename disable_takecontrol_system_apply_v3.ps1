#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$SystemWorker, [string]$LogPath, [string]$StatusPath, [switch]$AuditOnly)
$ErrorActionPreference = 'Stop'
$guid = 'b3f8fa53-0004-438e-9003-51a46e139bfc'
$pattern = '^\{' + [regex]::Escape($guid) + '\},\d+$'
function IsSystem { ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') }
function RunScan {
    $updated=0; $created=0; $unchanged=0; $nonDword=0; $failed=0; $devices=0
    foreach($type in @('Render','Capture')) {
        $root = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$type"
        try { $items = @(Get-ChildItem -LiteralPath $root -ErrorAction Stop) }
        catch { Write-Output "ERROR enumerating $type : $_"; $failed++; continue }
        foreach($device in $items) {
            $devices++
            $path = Join-Path $device.PSPath 'Properties'
            Write-Output "Scanning $type endpoint $($device.PSChildName)"
            if(-not (Test-Path -LiteralPath $path)) { Write-Output '  No Properties key'; continue }
            try {
                $key = Get-Item -LiteralPath $path -ErrorAction Stop
                $names = @($key.GetValueNames() | Where-Object { $_ -match $pattern })
                Write-Output "  Matching values: $($names.Count)"
                foreach($name in $names) {
                    try {
                        if($key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::DWord) { $nonDword++; Write-Output "  SKIP non-DWORD: $name"; continue }
                        $old = $key.GetValue($name)
                        if($old -eq 0) { $unchanged++; Write-Output "  ALREADY ZERO: $name"; continue }
                        if($AuditOnly) { Write-Output "  WOULD UPDATE (audit only): $name : $old -> 0"; continue }
                        # Request only SetValue access; no ownership or ACL modification.
                        $writable = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                            ($path -replace '^Microsoft.PowerShell.Core\\Registry::HKEY_LOCAL_MACHINE\\','' -replace '^HKEY_LOCAL_MACHINE\\','' -replace '^HKLM:\\',''),
                            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                            [System.Security.AccessControl.RegistryRights]::SetValue)
                        if($null -eq $writable) { throw 'Cannot open registry key for writing' }
                        try { $writable.SetValue($name, [int]0, [Microsoft.Win32.RegistryValueKind]::DWord) }
                        finally { $writable.Dispose() }
                        $verifyKey = Get-Item -LiteralPath $path -ErrorAction Stop
                        if($verifyKey.GetValue($name) -ne 0) { throw 'Verification failed' }
                        $updated++
                        Write-Output "  UPDATED $name : $old -> 0"
                    } catch { $failed++; Write-Output "  ERROR $name : $_" }
                }
                # Explicitly create or zero the two properties observed in the GUI comparison.
                # These must be processed even when absent from the original enumeration.
                foreach($suffix in @(3,4)) {
                    $targetName = '{' + $guid + '},' + $suffix
                    try {
                        $exists = @($key.GetValueNames()) -ccontains $targetName
                        if($exists -and $key.GetValueKind($targetName) -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
                            $nonDword++
                            Write-Output "  SKIP non-DWORD target: $targetName"
                            continue
                        }
                        $previous = if($exists) { $key.GetValue($targetName) } else { '<missing>' }
                        if($exists -and $previous -eq 0) {
                            $unchanged++
                            Write-Output "  ALREADY ZERO: $targetName"
                            continue
                        }
                        if($AuditOnly) {
                            Write-Output "  WOULD SET (audit only): $targetName : $previous -> 0"
                            continue
                        }
                        $relativePath = $path -replace '^Microsoft.PowerShell.Core\\Registry::HKEY_LOCAL_MACHINE\\','' -replace '^HKEY_LOCAL_MACHINE\\','' -replace '^HKLM:\\',''
                        $writable = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                            $relativePath,
                            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                            [System.Security.AccessControl.RegistryRights]::SetValue)
                        if($null -eq $writable) { throw 'Cannot open registry key for writing' }
                        try { $writable.SetValue($targetName, [int]0, [Microsoft.Win32.RegistryValueKind]::DWord) }
                        finally { $writable.Dispose() }
                        $verifyKey = Get-Item -LiteralPath $path -ErrorAction Stop
                        if(-not (@($verifyKey.GetValueNames()) -ccontains $targetName)) { throw 'Verification failed: value missing' }
                        if($verifyKey.GetValueKind($targetName) -ne [Microsoft.Win32.RegistryValueKind]::DWord -or $verifyKey.GetValue($targetName) -ne 0) { throw 'Verification failed: value not DWORD zero' }
                        if($exists) { $updated++; Write-Output "  UPDATED $targetName : $previous -> 0" }
                        else { $created++; Write-Output "  CREATED $targetName : DWORD 0" }
                    } catch { $failed++; Write-Output "  ERROR $targetName : $_" }
                }
            } catch { $failed++; Write-Output "  ERROR reading endpoint: $_" }
        }
    }
    Write-Output "SUMMARY endpoints=$devices updated=$updated created=$created alreadyZero=$unchanged nonDWORD=$nonDword failures=$failed"
    if($failed -gt 0) { Write-Output "EXITCODE: 1" } else { Write-Output "EXITCODE: 0" }
}
if($SystemWorker) {
    if(-not (IsSystem)) { throw 'SYSTEM worker was not launched as NT AUTHORITY\SYSTEM' }
    if(-not $LogPath -or -not $StatusPath) { throw 'Missing worker output paths' }
    $code=1
    try {
        $output = @(RunScan)
        $output | Where-Object { $_ -notmatch "^EXITCODE: " } | Out-File -LiteralPath $LogPath -Encoding UTF8 -Force
        $code = [int]($output[-1] -replace "^EXITCODE: ", "")
    } catch {
        "FATAL: $_" | Out-File -LiteralPath $LogPath -Encoding UTF8 -Append
    } finally {
        [IO.File]::WriteAllText($StatusPath, [string]$code)
    }
    exit $code
}
if(IsSystem) {
    $output = @(RunScan)
    $output | Where-Object { $_ -notmatch "^EXITCODE: " } | ForEach-Object { Write-Host $_ }
    exit ([int]($output[-1] -replace "^EXITCODE: ", ""))
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
Write-Host "Current identity: $identity" -ForegroundColor Cyan
Write-Host 'Launching registry scan as NT AUTHORITY\SYSTEM...' -ForegroundColor Cyan
if($AuditOnly) { Write-Host 'AUDIT MODE: no registry values will be changed.' -ForegroundColor Yellow } else { Write-Host 'APPLY MODE: zeroing all matching DWORDs and creating/zeroing suffixes 3 and 4 on Render and Capture endpoints.' -ForegroundColor Yellow }
$script = $PSCommandPath
if(-not $script) { throw 'Save this script as a .ps1 file before running it.' }
$folder = Join-Path $env:ProgramData 'AudioExclusiveSystem'
# SYSTEM task and elevated user share this restricted folder.
if(-not (Test-Path -LiteralPath $folder)) { New-Item -Path $folder -ItemType Directory -Force | Out-Null }
$acl = Get-Acl -LiteralPath $folder
$acl.SetAccessRuleProtection($true,$false)
foreach($rule in @($acl.Access)) { [void]$acl.RemoveAccessRuleAll($rule) }
foreach($sid in @('S-1-5-18','S-1-5-32-544')) {
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        (New-Object System.Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $folder -AclObject $acl
$id = [guid]::NewGuid().ToString('N')
$taskName = "AudioExclusive-$id"
$log = Join-Path $folder "$id.log"
$status = Join-Path $folder "$id.status"
$registered=$false
try {
    $ps = Join-Path $PSHOME 'powershell.exe'
    $auditArg = if($AuditOnly) { " -AuditOnly" } else { "" }
    $arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SystemWorker -LogPath "{1}" -StatusPath "{2}"{3}' -f $script,$log,$status,$auditArg)
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arguments
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    $registered=$true
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddMinutes(5)
    while(-not (Test-Path -LiteralPath $status) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
    if(-not (Test-Path -LiteralPath $status)) { throw 'SYSTEM task timed out. Check Task Scheduler operational logs.' }
    if(Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log | ForEach-Object { Write-Host $_ } }
    $exitCode = [int](Get-Content -LiteralPath $status -Raw).Trim()
    Write-Host "SYSTEM task exit code: $exitCode"
    exit $exitCode
} finally {
    if($registered) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $log,$status -Force -ErrorAction SilentlyContinue
}
