function Get-MemLabsWindowsOobeCompletion {
    if (-not ('MemLabs.WindowsOobeReadiness' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace MemLabs {
    public static class WindowsOobeReadiness {
        [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool OOBEComplete([MarshalAs(UnmanagedType.Bool)] out bool complete);
        public static bool ReadCompletion() {
            bool complete;
            if (!OOBEComplete(out complete)) {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, "OOBEComplete could not read completion state (native error " + error + ").");
            }
            return complete;
        }
    }
}
'@ -ErrorAction Stop
    }
    return [MemLabs.WindowsOobeReadiness]::ReadCompletion()
}

function Get-MemLabsWindowsOobeLifecycleState {
    return [string][Windows.System.Profile.SystemSetupInfo, Windows.System.Profile, ContentType=WindowsRuntime]::OutOfBoxExperienceState
}

function Get-MemLabsWindowsClientSetupState {
    $state = [pscustomobject]@{
        Version = 1; Required = $true; Ready = $false; ProductType = $null
        ImageState = $null; SetupType = $null; SystemSetupInProgress = $null
        OOBEInProgress = $null; NativeOobeComplete = $null
        WinRtOobeState = $null; SetupExeCompletion = $null
        OobeProcessCount = $null; OobeProcesses = @()
        ActiveName = $null; PendingName = $null
        Reason = 'ProbeFailed'; Detail = ''; Diagnostics = @()
    }
    try {
        $systems = @(Get-CimInstance -ClassName Win32_OperatingSystem -OperationTimeoutSec 5 -ErrorAction Stop)
        $productType = if ($systems.Count -eq 1) { $systems[0].PSObject.Properties['ProductType'] } else { $null }
        if (-not $productType -or ($productType.Value -isnot [int] -and $productType.Value -isnot [uint32]) -or
            $productType.Value -notin @(1, 2, 3)) {
            throw 'Windows product type could not be established.'
        }
        $state.ProductType = [int]$productType.Value
        if ($state.ProductType -in @(2, 3)) {
            $state.Required = $false
            $state.Ready = $true
            $state.Reason = 'NotWindowsClient'
            $state.Detail = "Windows client setup gate is not required (ProductType=$($state.ProductType))."
            return $state
        }

        $image = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Setup\State' `
            -Name ImageState -ErrorAction Stop
        if ($image.ImageState -isnot [string] -or [string]::IsNullOrWhiteSpace($image.ImageState)) {
            throw 'Windows ImageState is missing or invalid.'
        }
        $state.ImageState = $image.ImageState
        $setup = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup' -ErrorAction Stop
        foreach ($name in @('SetupType', 'SystemSetupInProgress', 'OOBEInProgress')) {
            $property = $setup.PSObject.Properties[$name]
            if (-not $property -or ($property.Value -isnot [int] -and $property.Value -isnot [uint32]) -or
                $property.Value -lt 0) {
                throw "Windows setup value '$name' is missing or invalid."
            }
            $state.$name = $property.Value
        }
        $state.ActiveName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' `
                -Name ComputerName -ErrorAction Stop).ComputerName
        $state.PendingName = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' `
                -Name ComputerName -ErrorAction Stop).ComputerName
        if ($state.ActiveName -isnot [string] -or [string]::IsNullOrWhiteSpace($state.ActiveName) -or
            $state.PendingName -isnot [string] -or [string]::IsNullOrWhiteSpace($state.PendingName)) {
            throw 'Active or pending computer name is unavailable.'
        }
        $native = @(Get-MemLabsWindowsOobeCompletion)
        if ($native.Count -ne 1 -or $native[0] -isnot [bool]) {
            throw 'The native OOBE completion API did not return one Boolean.'
        }
        $state.NativeOobeComplete = $native[0]
        if ($state.ImageState -ne 'IMAGE_STATE_COMPLETE' -or $state.SetupType -ne 0 -or
            $state.SystemSetupInProgress -ne 0 -or $state.OOBEInProgress -ne 0) {
            $state.Reason = 'MachineSetupIncomplete'
        }
        elseif (-not $state.NativeOobeComplete) {
            $state.Reason = 'WindowsWelcomeIncomplete'
            $userStates = @(Get-MemLabsWindowsOobeLifecycleState)
            if ($userStates.Count -ne 1 -or $userStates[0] -isnot [string] -or
                $userStates[0] -notin @('NotStarted', 'InProgress', 'Completed')) {
                throw 'The WinRT OOBE lifecycle API did not return one supported state.'
            }
            $state.WinRtOobeState = $userStates[0]
            if ($state.WinRtOobeState -eq 'Completed') {
                throw 'Native and WinRT OOBE completion signals disagree.'
            }
            if ($state.WinRtOobeState -eq 'NotStarted') {
                $completion = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\Setup\Status\ChildCompletion' `
                    -Name 'setup.exe' -ErrorAction Stop
                $property = $completion.PSObject.Properties['setup.exe']
                if (-not $property -or ($property.Value -isnot [int] -and $property.Value -isnot [uint32]) -or
                    $property.Value -lt 0) {
                    throw 'Windows setup.exe completion state is missing or invalid.'
                }
                $state.SetupExeCompletion = $property.Value
                if ($state.SetupExeCompletion -ne 3) { $state.Reason = 'MachineSetupIncomplete' }
                else {
                    $processes = @(Get-CimInstance -ClassName Win32_Process -OperationTimeoutSec 5 -ErrorAction Stop `
                        -Filter "Name='setup.exe' OR Name='setuphost.exe' OR Name='msoobe.exe' OR Name='oobeldr.exe' OR Name='oobelauncher.exe' OR Name='UserOOBEBroker.exe' OR Name='CloudExperienceHostBroker.exe' OR Name='CloudExperienceHost.exe' OR Name='WWAHost.exe' OR Name='FirstLogonAnim.exe'")
                    foreach ($process in $processes) {
                        $nameProperty = $process.PSObject.Properties['Name']
                        if (-not $nameProperty -or $nameProperty.Value -isnot [string] -or
                            [string]::IsNullOrWhiteSpace($nameProperty.Value)) {
                            throw 'The OOBE process query returned an unreadable process name.'
                        }
                    }
                    $state.OobeProcessCount = $processes.Count
                    $state.OobeProcesses = @($processes | ForEach-Object { $_.Name })
                    if ($state.OobeProcessCount -eq 0) {
                        $state.Ready = $true
                        $state.Reason = 'MachineCompleteAwaitingFirstLogon'
                    }
                }
            }
        }
        else { $state.Ready = $true; $state.Reason = 'Complete' }
    }
    catch { $state.Reason = 'ProbeFailed'; $state.Diagnostics = @($_.Exception.Message) }

    $details = foreach ($name in @('ProductType', 'ImageState', 'SetupType', 'SystemSetupInProgress',
            'OOBEInProgress', 'NativeOobeComplete', 'WinRtOobeState', 'SetupExeCompletion',
            'OobeProcessCount', 'OobeProcesses', 'ActiveName', 'PendingName')) {
        $value = if ($null -eq $state.$name) { '<unavailable>' } else { "$($state.$name)" }
        "${name}=$value"
    }
    $state.Detail = "$($state.Reason): $($details -join ' '); $($state.Diagnostics -join '; ')"
    return $state
}
