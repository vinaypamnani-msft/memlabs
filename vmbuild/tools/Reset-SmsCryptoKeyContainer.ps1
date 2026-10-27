#requires -Version 5.1
<#
.SYNOPSIS
    PowerShell replica of the CryptImportKey.exe SMS/ConfigMgr crypto key-container tool.

.DESCRIPTION
    Reimplements the native CryptoAPI (advapi32) behavior of CryptImportKey.cpp against the
    legacy CAPI *machine* key container named "Microsoft Systems Management Server", served by
    the "Microsoft Enhanced RSA and AES Cryptographic Provider" (PROV_RSA_AES = 24).

    The compiled main() of the original program DELETES that container
    (CryptAcquireContext with CRYPT_DELETEKEYSET | CRYPT_MACHINE_KEYSET); the commented-out
    _tmain RESETS it (CRYPT_NEWKEYSET | CRYPT_MACHINE_KEYSET). This script exposes both, plus a
    non-destructive existence check, via CryptAcquireContext P/Invoke -- no compiler needed.

    This is the classic ConfigMgr recovery move for a corrupt SMS crypto container (e.g. the
    machine keys were regenerated and the old container can no longer be decrypted). After a
    delete/reset the site server regenerates the container; a reboot is recommended.

.PARAMETER Action
    Check   - non-destructively test whether the container exists (default).
    Delete  - delete the container (mirrors the compiled main()). Idempotent-ish: a second
              Delete fails with NTE_BAD_KEYSET (0x80090016) proving it is gone.
    Reset   - delete if present, then create a fresh empty container (mirrors _tmain).

.EXAMPLE
    # Must run as SYSTEM (or elevated admin) -- the container is in the MACHINE keyset.
    .\Reset-SmsCryptoKeyContainer.ps1 -Action Check

.EXAMPLE
    .\Reset-SmsCryptoKeyContainer.ps1 -Action Delete
    .\Reset-SmsCryptoKeyContainer.ps1 -Action Delete   # run again to verify it's gone

.EXAMPLE
    .\Reset-SmsCryptoKeyContainer.ps1 -Action Reset    # then reboot
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Check', 'Delete', 'Reset')]
    [string]$Action = 'Check',

    [string]$ContainerName = 'Microsoft Systems Management Server',

    [string]$ProviderName = 'Microsoft Enhanced RSA and AES Cryptographic Provider'
)

$ErrorActionPreference = 'Stop'

# PROV_RSA_AES; matches the C++ "24" passed to CryptAcquireContext.
$PROV_RSA_AES = 24

# dwFlags values from wincrypt.h (same constants the C++ used).
$CRYPT_NEWKEYSET     = 0x00000008
$CRYPT_DELETEKEYSET  = 0x00000010
$CRYPT_MACHINE_KEYSET = 0x00000020
$CRYPT_SILENT        = 0x00000040

if (-not ('MemLabs.SmsCapi' -as [type])) {
    Add-Type -Namespace 'MemLabs' -Name 'SmsCapi' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Ansi)]
public static extern bool CryptAcquireContext(
    out System.IntPtr hProv,
    string pszContainer,
    string pszProvider,
    uint dwProvType,
    uint dwFlags);

[System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError = true)]
public static extern bool CryptReleaseContext(System.IntPtr hProv, uint dwFlags);
'@
}

function Invoke-Acquire {
    param([string]$Container, [string]$Provider, [uint32]$Flags)
    $hProv = [IntPtr]::Zero
    $ok = [MemLabs.SmsCapi]::CryptAcquireContext([ref]$hProv, $Container, $Provider, [uint32]$PROV_RSA_AES, $Flags)
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    # For delete/new flags no usable handle is returned; only release a real handle.
    if ($ok -and $hProv -ne [IntPtr]::Zero -and (($Flags -band $CRYPT_DELETEKEYSET) -eq 0)) {
        [void][MemLabs.SmsCapi]::CryptReleaseContext($hProv, 0)
    }
    [pscustomobject]@{ Success = $ok; Error = $err }
}

function ConvertTo-UInt32Code {
    param([int]$Code)
    # GetLastWin32Error returns a signed int; mask through a long so 0x8009xxxx codes
    # (which are negative as int) convert cleanly to uint32.
    return [uint32]($Code -band 0xFFFFFFFFL)
}

function Format-CapiError {
    param([int]$Code)
    $u = ConvertTo-UInt32Code $Code
    $hex = '0x{0:X8}' -f $u
    $name = switch ($u) {
        0x80090016L { 'NTE_BAD_KEYSET (container does not exist)' }
        0x8009000FL { 'NTE_EXISTS (container already exists)' }
        0x80090006L { 'NTE_BAD_SIGNATURE (invalid signature -- container keys unreadable)' }
        0x5        { 'ERROR_ACCESS_DENIED (run as SYSTEM / elevated)' }
        default    { ([System.ComponentModel.Win32Exception]$Code).Message }
    }
    "$hex $name"
}

Write-Host "Started (PowerShell replica of CryptImportKey.exe)" -ForegroundColor Cyan
Write-Host "  Container : $ContainerName"
Write-Host "  Provider  : $ProviderName (PROV_RSA_AES=$PROV_RSA_AES)"
Write-Host "  Action    : $Action`n"

switch ($Action) {

    'Check' {
        # Non-destructive: open the machine keyset container silently.
        $r = Invoke-Acquire -Container $ContainerName -Provider $ProviderName -Flags ($CRYPT_MACHINE_KEYSET -bor $CRYPT_SILENT)
        if ($r.Success) {
            Write-Host "EXISTS: SMS key container is present and openable." -ForegroundColor Green
        }
        elseif ((ConvertTo-UInt32Code $r.Error) -eq 0x80090016L) {
            Write-Host "ABSENT: SMS key container does not exist (NTE_BAD_KEYSET)." -ForegroundColor Yellow
        }
        else {
            Write-Host "OPEN FAILED: $(Format-CapiError $r.Error)" -ForegroundColor Red
            Write-Host "  (0x80090006 here means the container exists but its keys can't be decrypted -> Reset it.)"
        }
    }

    'Delete' {
        if ($PSCmdlet.ShouldProcess($ContainerName, 'CryptAcquireContext CRYPT_DELETEKEYSET (delete SMS key container)')) {
            $r = Invoke-Acquire -Container $ContainerName -Provider $ProviderName -Flags ($CRYPT_DELETEKEYSET -bor $CRYPT_MACHINE_KEYSET)
            if ($r.Success) {
                Write-Host "Successfully Deleted Keyset.. run -Action Delete again to verify it is deleted." -ForegroundColor Green
            }
            elseif ((ConvertTo-UInt32Code $r.Error) -eq 0x80090016L) {
                Write-Host "Already deleted: container not found (NTE_BAD_KEYSET) -- nothing to do." -ForegroundColor Yellow
            }
            else {
                Write-Host "Delete: Something went wrong. Are you running as SYSTEM? ERROR: $(Format-CapiError $r.Error)" -ForegroundColor Red
            }
        }
    }

    'Reset' {
        if ($PSCmdlet.ShouldProcess($ContainerName, 'Delete then create a fresh SMS key container, then reboot')) {
            # 1) Delete existing (ignore "not found").
            $del = Invoke-Acquire -Container $ContainerName -Provider $ProviderName -Flags ($CRYPT_DELETEKEYSET -bor $CRYPT_MACHINE_KEYSET)
            if ($del.Success) {
                Write-Host "  Deleted existing container." -ForegroundColor DarkGray
            }
            elseif ((ConvertTo-UInt32Code $del.Error) -eq 0x80090016L) {
                Write-Host "  No existing container to delete." -ForegroundColor DarkGray
            }
            else {
                Write-Host "  Delete step warning: $(Format-CapiError $del.Error)" -ForegroundColor Yellow
            }

            # 2) Create a brand-new empty container (mirrors the commented-out _tmain).
            $new = Invoke-Acquire -Container $ContainerName -Provider $ProviderName -Flags ($CRYPT_NEWKEYSET -bor $CRYPT_MACHINE_KEYSET -bor $CRYPT_SILENT)
            if ($new.Success) {
                Write-Host "$ContainerName Key reset. Please Reboot." -ForegroundColor Green
            }
            else {
                Write-Host "Reset: create failed with $(Format-CapiError $new.Error)" -ForegroundColor Red
            }
        }
    }
}
