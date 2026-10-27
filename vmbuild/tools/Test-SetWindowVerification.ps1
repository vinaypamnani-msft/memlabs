<#
.SYNOPSIS
    Verifies that moving a window without resizing it is not reported as a failure.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$commonPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Common.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($commonPath, [ref]$tokens, [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    throw "Common.ps1 has $($parseErrors.Count) parse error(s): $($parseErrors -join '; ')"
}

$setWindowFunctions = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Set-Window'
        }, $true))
if ($setWindowFunctions.Count -ne 1) {
    throw "Expected one Set-Window function; found $($setWindowFunctions.Count)."
}

Add-Type @'
using System;

public struct RECT
{
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
}

public static class Window
{
    private static RECT current = new RECT { Left = 10, Top = 10, Right = 110, Bottom = 90 };

    public static bool GetWindowRect(IntPtr handle, out RECT rectangle)
    {
        rectangle = current;
        return true;
    }

    public static bool MoveWindow(IntPtr handle, int x, int y, int width, int height, bool redraw)
    {
        current = new RECT { Left = x, Top = y, Right = x + width, Bottom = y + height };
        return true;
    }

    public static bool IsWindowVisible(IntPtr handle) { return true; }
    public static IntPtr FindWindow(string className, string windowName) { return IntPtr.Zero; }
    public static IntPtr GetConsoleWindow() { return new IntPtr(1); }
}
'@

$script:WindowLogs = [System.Collections.Generic.List[object]]::new()
function Write-Log {
    param(
        [Parameter(Position = 0)] [string] $Message,
        [switch] $LogOnly,
        [switch] $Warning
    )
    $script:WindowLogs.Add([pscustomobject]@{ Message = $Message; Warning = $Warning.IsPresent })
}

Invoke-Expression $setWindowFunctions[0].Extent.Text
Set-Window -ProcessID $PID -X 20 -Y 20

$warnings = @($script:WindowLogs | Where-Object Warning)
if ($warnings.Count -ne 0) {
    throw "A successful position-only move emitted warning(s): $($warnings.Message -join ' | ')"
}

$after = @($script:WindowLogs | Where-Object Message -like 'Set-Window: PID * AFTER=*')
if ($after.Count -ne 1 -or $after[0].Message -notmatch 'AFTER=100x80 at \(20,20\)') {
    throw "Set-Window did not reach the requested rectangle: $($after.Message -join ' | ')"
}

Write-Host 'PASS -- a successful position-only window move emits no warning.'
