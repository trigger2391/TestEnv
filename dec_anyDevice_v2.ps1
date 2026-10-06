# ==========================================
# Script Name: disable_takecontrol.ps1
# Author: Matthew Bernardin
# Version: 04/10/2026
# ==========================================

#Requires -RunAsAdministrator

$failureCount = 0
$updatedDevices = 0
$skippedDevices = 0

# Commonly used exclusive-mode properties.
# One of these could work but needs testing against individual windows builds or as a future update a for loop to iteratively discover every variable
$propertyNames = @(
    "{b3f8fa53-0004-438e-9003-51a46e139bfc},0"
    "{b3f8fa53-0004-438e-9003-51a46e139bfc},3"
    "{b3f8fa53-0004-438e-9003-51a46e139bfc},4"
)

$basePaths = [ordered]@{
    Playback = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render"
    Capture  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture"
}

foreach ($type in $basePaths.Keys) {
    try {
        $devices = @(
            Get-ChildItem -LiteralPath $basePaths[$type] -ErrorAction Stop
        )
    }
    catch {
        Write-Warning "Failed to enumerate ${type} devices: $($_.Exception.Message)"
        $failureCount++
        continue
    }

    foreach ($device in $devices) {
        $propertiesPath = Join-Path -Path $device.PSPath -ChildPath "Properties"

        try {
            if (-not (Test-Path -LiteralPath $propertiesPath -ErrorAction Stop)) {
                Write-Output "Skipped ${type} device $($device.PSChildName): no Properties key."
                $skippedDevices++
                continue
            }

            $key = Get-Item -LiteralPath $propertiesPath -ErrorAction Stop
            $existingNames = @($key.GetValueNames())
            $changed = $false

            foreach ($propertyName in $propertyNames) {
                if ($existingNames -notcontains $propertyName) {
                    continue
                }

                if ($key.GetValueKind($propertyName) -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
                    throw "Property '$propertyName' is not a DWORD; no change made to this property."
                }

                New-ItemProperty `
                    -LiteralPath $propertiesPath `
                    -Name $propertyName `
                    -Value 0 `
                    -PropertyType DWord `
                    -Force `
                    -ErrorAction Stop | Out-Null

                $actualValue = Get-ItemPropertyValue `
                    -LiteralPath $propertiesPath `
                    -Name $propertyName `
                    -ErrorAction Stop

                if ($actualValue -ne 0) {
                    throw "Verification failed for '$propertyName'."
                }

                $changed = $true
            }

            if ($changed) {
                $updatedDevices++
                Write-Output "Updated ${type} device: $($device.PSChildName)"
            }
            else {
                $skippedDevices++
                Write-Output "Skipped ${type} device $($device.PSChildName): exclusive-mode values absent."
            }
        }
        catch {
            $failureCount++
            Write-Warning "Failed ${type} device $($device.PSChildName): $($_.Exception.Message)"
        }
    }
}

# Discover Windows 365 / Windows App packages for the current user.
# If multiple candidates exist, require an explicit selection.
# Set this to the actual PackageFamilyName to select a specific app.
$targetPFN = ""

try {
    if ([string]::IsNullOrWhiteSpace($targetPFN)) {
        $candidates = @(
            Get-AppxPackage -ErrorAction Stop |
                Where-Object {
                    $_.Name -match 'Windows365|WindowsApp|RemoteDesktop'
                }
        )

        if ($candidates.Count -eq 0) {
            throw "No matching app package found. Set `$targetPFN to the installed app's PackageFamilyName."
        }

        if ($candidates.Count -gt 1) {
            $names = ($candidates.PackageFamilyName -join ", ")
            throw "Multiple app packages found: $names. Set `$targetPFN to the intended package."
        }

        $targetPFN = $candidates[0].PackageFamilyName
    }

    $installedPackage = @(
        Get-AppxPackage -ErrorAction Stop |
            Where-Object { $_.PackageFamilyName -eq $targetPFN }
    )

    if ($installedPackage.Count -eq 0) {
        throw "Package '$targetPFN' is not installed for the current user."
    }

    $microphonePath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone"
    $appPath = Join-Path -Path $microphonePath -ChildPath $targetPFN

    if (-not (Test-Path -LiteralPath $appPath -ErrorAction Stop)) {
        New-Item -Path $appPath -Force -ErrorAction Stop | Out-Null
    }

    New-ItemProperty `
        -LiteralPath $appPath `
        -Name "Value" `
        -Value "Allow" `
        -PropertyType String `
        -Force `
        -ErrorAction Stop | Out-Null

    $actualPermission = Get-ItemPropertyValue `
        -LiteralPath $appPath `
        -Name "Value" `
        -ErrorAction Stop

    if ($actualPermission -ne "Allow") {
        throw "Microphone registry value verification failed."
    }

    Write-Output "Microphone consent registry value set to Allow for: $targetPFN"
}
catch {
    $failureCount++
    Write-Warning "Failed to set microphone consent: $($_.Exception.Message)"
}

Write-Output ""
Write-Output "Devices updated: $updatedDevices"
Write-Output "Devices skipped: $skippedDevices"
Write-Output "Failures: $failureCount"

if ($failureCount -gt 0) {
    exit 1
}

exit 0
