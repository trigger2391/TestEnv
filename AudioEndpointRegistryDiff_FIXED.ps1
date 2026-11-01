#requires -version 5.1
<#
.SYNOPSIS
  Read-only snapshots and automatic before/after comparison of audio endpoint registry values.
.DESCRIPTION
  Run once, change audio exclusive-mode setting in Windows GUI, run again.
  The second and subsequent runs compare the newest snapshot with its predecessor.
  Reads all values under every endpoint's Properties key and endpoint root key,
  including subkeys. Captures value type and exact byte representation.
.PARAMETER OutputDirectory
  Directory for snapshots and comparison files (defaults to a folder beside this script).
.PARAMETER NoCompare
  Capture only; do not automatically compare with the previous snapshot.
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [switch]$NoCompare
)

$ErrorActionPreference = 'Stop'

# Resolve the output location at runtime, not during parameter binding.
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $scriptDirectory = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptDirectory = (Get-Location).Path
    }
    $OutputDirectory = Join-Path -Path $scriptDirectory -ChildPath 'AudioEndpointSnapshots'
}

$base = 'SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
$hive = [Microsoft.Win32.Registry]::LocalMachine
$rows = New-Object 'System.Collections.Generic.List[object]'
$issues = New-Object 'System.Collections.Generic.List[object]'

function To-ExactText($data, [Microsoft.Win32.RegistryValueKind]$kind) {
    if ($null -eq $data) { return '' }
    switch ($kind.ToString()) {
        'Binary' { return [Convert]::ToBase64String([byte[]]$data) }
        'DWord' { return ('0x{0:X8}' -f ([uint32]([int64]$data -band 0xFFFFFFFFL))) }
        'QWord' { return ('0x{0:X16}' -f ([uint64]$data)) }
        'MultiString' { return (ConvertTo-Json -InputObject @($data) -Compress -Depth 4) }
        default { return [string]$data }
    }
}

function Read-KeyRecursive([string]$relative, [string]$direction, [string]$endpoint) {
    $key = $null
    try {
        $key = $hive.OpenSubKey($relative, $false)
        if ($null -eq $key) { throw "Could not open registry key" }
        foreach ($name in $key.GetValueNames()) {
            try {
                $kind = $key.GetValueKind($name)
                $value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $rows.Add([pscustomobject]@{
                    Direction = $direction
                    Endpoint = $endpoint
                    Key = "HKLM\$relative"
                    ValueName = $name
                    Kind = $kind.ToString()
                    Data = (To-ExactText $value $kind)
                })
            } catch {
                $issues.Add([pscustomobject]@{ Path = "HKLM\$relative [$name]"; Error = $_.Exception.Message })
            }
        }
        $children = @($key.GetSubKeyNames())
    } catch {
        $issues.Add([pscustomobject]@{ Path = "HKLM\$relative"; Error = $_.Exception.Message })
        return
    } finally {
        if ($null -ne $key) { $key.Close() }
    }
    foreach ($child in $children) { Read-KeyRecursive "$relative\$child" $direction $endpoint }
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$existing = @(Get-ChildItem -LiteralPath $OutputDirectory -Filter 'audio_snapshot_*.csv' -File | Sort-Object Name)
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fffffff'
$snapshot = Join-Path $OutputDirectory "audio_snapshot_$stamp.csv"

foreach ($direction in @('Render', 'Capture')) {
    $branch = "$base\$direction"
    $root = $null
    try {
        $root = $hive.OpenSubKey($branch, $false)
        if ($null -eq $root) { throw "Branch not found" }
        $endpoints = @($root.GetSubKeyNames())
    } catch {
        $issues.Add([pscustomobject]@{ Path = "HKLM\$branch"; Error = $_.Exception.Message })
        continue
    } finally { if ($null -ne $root) { $root.Close() } }
    foreach ($endpoint in $endpoints) {
        Write-Host "Reading $direction $endpoint"
        Read-KeyRecursive "$branch\$endpoint" $direction $endpoint
    }
}

$rows | Sort-Object Key, ValueName | Export-Csv -LiteralPath $snapshot -NoTypeInformation -Encoding UTF8
Write-Host "`nSnapshot saved: $snapshot" -ForegroundColor Green
Write-Host "Values captured: $($rows.Count); read errors: $($issues.Count)"
if ($issues.Count -gt 0) {
    $errorPath = Join-Path $OutputDirectory "audio_read_errors_$stamp.csv"
    $issues | Export-Csv -LiteralPath $errorPath -NoTypeInformation -Encoding UTF8
    Write-Warning "Some keys or values could not be read. Details: $errorPath"
}

if (-not $NoCompare -and $existing.Count -gt 0) {
    $previous = $existing[-1].FullName
    Write-Host "`nComparing against: $previous"
    $oldRows = @(Import-Csv -LiteralPath $previous)
    $newRows = @(Import-Csv -LiteralPath $snapshot)
    $oldMap = @{}
    $newMap = @{}
    foreach ($r in $oldRows) { $oldMap[($r.Key + [char]0 + $r.ValueName)] = $r }
    foreach ($r in $newRows) { $newMap[($r.Key + [char]0 + $r.ValueName)] = $r }
    $allKeys = @(@($oldMap.Keys) + @($newMap.Keys) | Sort-Object -Unique)
    $changes = New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in $allKeys) {
        $before = $oldMap[$id]
        $after = $newMap[$id]
        $status = $null
        if ($null -eq $before) { $status = 'Added' }
        elseif ($null -eq $after) { $status = 'Removed' }
        elseif ($before.Kind -cne $after.Kind -or $before.Data -cne $after.Data) { $status = 'Changed' }
        if ($status) {
            $r = if ($null -ne $after) { $after } else { $before }
            $changes.Add([pscustomobject]@{
                Change = $status
                Direction = $r.Direction
                Endpoint = $r.Endpoint
                Key = $r.Key
                ValueName = $r.ValueName
                BeforeKind = if ($null -ne $before) { $before.Kind } else { '' }
                BeforeData = if ($null -ne $before) { $before.Data } else { '' }
                AfterKind = if ($null -ne $after) { $after.Kind } else { '' }
                AfterData = if ($null -ne $after) { $after.Data } else { '' }
            })
        }
    }
    $diffFile = Join-Path $OutputDirectory "audio_diff_$stamp.csv"
    if ($changes.Count -gt 0) {
        $changes | Export-Csv -LiteralPath $diffFile -NoTypeInformation -Encoding UTF8
        $changes | Select-Object Change,Direction,Endpoint,ValueName,BeforeData,AfterData | Format-Table -AutoSize -Wrap
        Write-Host "Changes found: $($changes.Count)" -ForegroundColor Cyan
        Write-Host "Full difference report: $diffFile" -ForegroundColor Green
    } else {
        'No registry value changes detected.' | Set-Content -LiteralPath ($diffFile -replace '\.csv$', '.txt') -Encoding UTF8
        Write-Host 'No registry value changes detected.' -ForegroundColor Yellow
    }
}
elseif (-not $NoCompare) {
    Write-Host 'First snapshot complete. Change the checkbox in Windows, then run this same script again.' -ForegroundColor Cyan
}
