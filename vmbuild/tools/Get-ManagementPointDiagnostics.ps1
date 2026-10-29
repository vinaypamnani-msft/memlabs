<#
.SYNOPSIS
    Collects read-only MP installation and owning-site evidence.
.DESCRIPTION
    Used automatically after role failures. Can also run locally in the guest;
    Windows PowerShell 5.1 is recommended for the WebAdministration provider.
    AsJson returns one document without writing a file.

    Compares the exact IIS provider probe with selected applicationHost.config
    fields and appcmd output. Does not export the complete IIS configuration,
    credentials, or certificate private keys. SiteServerOnly collects services,
    installation paths, and site logs without requiring a local MP.

    Searches known log directories on all ready fixed drives. Logs up to 8 MiB
    are retained in full; larger files retain their last 6000 lines. Capture
    modes, missing evidence, and probe failures are recorded explicitly.
    Does not install software, restart services, or change configuration.
.EXAMPLE
    .\Get-ManagementPointDiagnostics.ps1 -SiteCode PS1
.EXAMPLE
    .\Get-ManagementPointDiagnostics.ps1 -SiteServerOnly -AsJson
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9]{3}$')]
    [string] $SiteCode,
    [switch] $SiteServerOnly,
    [string] $OutputPath,
    [switch] $AsJson
)

$ErrorActionPreference = 'Stop'
if ($AsJson -and $PSBoundParameters.ContainsKey('OutputPath')) {
    throw 'Use either AsJson or OutputPath, not both.'
}

function Get-ManagementPointDiagnosticProbe {
    param([string] $Name, [scriptblock] $Action)

    try {
        $data = @(& $Action)
        [pscustomobject]@{ Name = $Name; Success = $true; Data = $data; Error = $null }
    }
    catch {
        [pscustomobject]@{
            Name = $Name
            Success = $false
            Data = @()
            Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message); FQID=$($_.FullyQualifiedErrorId); $($_.ScriptStackTrace)"
        }
    }
}

function Invoke-ManagementPointDiagnosticNative {
    param([string] $FilePath, [string[]] $Arguments)

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf -ErrorAction Stop)) {
        throw "Diagnostic executable is absent: $FilePath"
    }
    $savedPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedPreference }
    $text = ($output | ForEach-Object { "$_" }) -join "`r`n"
    if ($exitCode -ne 0) { throw "$FilePath exited $exitCode`: $text" }
    $text
}

$probes = [System.Collections.Generic.List[object]]::new()
$logs = [System.Collections.Generic.List[object]]::new()
$collectionErrors = [System.Collections.Generic.List[string]]::new()
$addProbe = {
    param([string] $Name, [scriptblock] $Action)
    $probe = Get-ManagementPointDiagnosticProbe -Name $Name -Action $Action
    $probes.Add($probe)
    if (-not $probe.Success) { $collectionErrors.Add("$Name`: $($probe.Error)") }
    $probe
}

$null = & $addProbe 'Services' {
    Get-Service -ErrorAction Stop |
        Where-Object { $_.Name -in @('W3SVC', 'WAS', 'SMS_EXECUTIVE', 'SMS_SITE_COMPONENT_MANAGER', 'CcmExec') } |
        Select-Object Name, @{ Name = 'Status'; Expression = { "$($_.Status)" } }
}
$installation = & $addProbe 'InstallationPaths' {
    foreach ($spec in @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\SMS\Setup'; Name = 'Installation Directory' },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\SMS\Tracing'; Name = 'LogDirectory' }
        )) {
        if (Test-Path -LiteralPath $spec.Path -ErrorAction Stop) {
            $item = Get-ItemProperty -LiteralPath $spec.Path -ErrorAction Stop
            $property = $item.PSObject.Properties[$spec.Name]
            if ($property -and $property.Value) {
                [pscustomobject]@{ RegistryPath = $spec.Path; Name = $spec.Name; Value = "$($property.Value)" }
            }
        }
        $null = & $addProbe 'FeatureReceipts' {
            foreach ($marker in @(Get-ChildItem -Path 'C:\staging\InstallFeatureStatus*.txt' -File -ErrorAction Stop)) {
                $lines = @(Get-Content -LiteralPath $marker.FullName -TotalCount 2 -ErrorAction Stop)
                [pscustomobject]@{
                    Path = $marker.FullName
                    LastWriteTimeUtc = $marker.LastWriteTimeUtc
                    Signature = if ($lines.Count) { "$($lines[0])" } else { '' }
                    Verified = $lines.Count -eq 2 -and ([string]$lines[1]).Trim() -eq 'MemLabsFeatureStateVerified=1'
                }
            }
        }
    }
}

if (-not $SiteServerOnly) {
    $null = & $addProbe 'MpRegistryPresence' {
        [pscustomobject]@{ Present = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\SMS\MP' -ErrorAction Stop }
    }
    $null = & $addProbe 'IisProviderEndpoint' {
        Import-Module WebAdministration -ErrorAction Stop
        $path = 'IIS:\Sites\Default Web Site\SMS_MP'
        $exists = Test-Path -LiteralPath $path -ErrorAction Stop
        $endpoint = $null
        if ($exists) {
            $endpoint = Get-Item -LiteralPath $path -ErrorAction Stop |
                Select-Object Name, PhysicalPath, ApplicationPool
        }
        [pscustomobject]@{ Path = $path; Exists = [bool]$exists; Endpoint = $endpoint }
    }
    $null = & $addProbe 'IisApplications' {
        Import-Module WebAdministration -ErrorAction Stop
        Get-WebApplication -Site 'Default Web Site' -ErrorAction Stop |
            Select-Object Path, PhysicalPath, ApplicationPool
    }
    $null = & $addProbe 'IisVirtualDirectories' {
        Import-Module WebAdministration -ErrorAction Stop
        Get-WebVirtualDirectory -Site 'Default Web Site' -ErrorAction Stop |
            Select-Object Path, PhysicalPath
    }
    $null = & $addProbe 'IisBindings' {
        Import-Module WebAdministration -ErrorAction Stop
        Get-WebBinding -ErrorAction Stop |
            Select-Object ItemXPath, Protocol, BindingInformation, CertificateHash, CertificateStoreName, SslFlags
    }
    $null = & $addProbe 'IisApplicationPools' {
        Import-Module WebAdministration -ErrorAction Stop
        Get-ChildItem -LiteralPath 'IIS:\AppPools' -ErrorAction Stop |
            Select-Object Name, State, ManagedRuntimeVersion, ManagedPipelineMode, Enable32BitAppOnWin64
    }
    $null = & $addProbe 'IisConfigurationFile' {
        $path = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
        $config = [xml](Get-Content -LiteralPath $path -Raw -ErrorAction Stop)
        $sites = @(foreach ($site in $config.SelectNodes('/configuration/system.applicationHost/sites/site')) {
                $applications = @(foreach ($app in $site.SelectNodes('application')) {
                        $directories = @(foreach ($directory in $app.SelectNodes('virtualDirectory')) {
                                $physicalPath = [Environment]::ExpandEnvironmentVariables($directory.GetAttribute('physicalPath'))
                                $urlPath = ($app.GetAttribute('path').TrimEnd('/') + '/' + $directory.GetAttribute('path').TrimStart('/')).TrimEnd('/')
                                [pscustomobject]@{
                                    Path = $directory.GetAttribute('path')
                                    UrlPath = $urlPath
                                    IsSmsMp = $urlPath -ieq '/SMS_MP'
                                    PhysicalPath = $physicalPath
                                    PhysicalDirectoryExists = Test-Path -LiteralPath $physicalPath -PathType Container -ErrorAction Stop
                                }
                            })
                        [pscustomobject]@{
                            Path = $app.GetAttribute('path')
                            ApplicationPool = $app.GetAttribute('applicationPool')
                            VirtualDirectories = $directories
                        }
                    })
                [pscustomobject]@{
                    Name = $site.GetAttribute('name')
                    Id = $site.GetAttribute('id')
                    Bindings = @($site.SelectNodes('bindings/binding') | ForEach-Object {
                            [pscustomobject]@{ Protocol = $_.GetAttribute('protocol'); BindingInformation = $_.GetAttribute('bindingInformation') }
                        })
                    Applications = $applications
                }
            })
        [pscustomobject]@{ SourcePath = $path; Sites = $sites }
    }
    $null = & $addProbe 'AppCmdVirtualDirectories' {
        Invoke-ManagementPointDiagnosticNative -FilePath (Join-Path $env:windir 'System32\inetsrv\appcmd.exe') -Arguments @('list', 'vdir', '/xml')
    }
    $null = & $addProbe 'HttpSysSslBindings' {
        Invoke-ManagementPointDiagnosticNative -FilePath (Join-Path $env:windir 'System32\netsh.exe') -Arguments @('http', 'show', 'sslcert')
    }
    $null = & $addProbe 'PublicCertificateMetadata' {
        foreach ($certificate in @(Get-ChildItem -LiteralPath 'Cert:\LocalMachine\My' -ErrorAction Stop)) {
            [pscustomobject]@{
                Subject = $certificate.Subject
                Issuer = $certificate.Issuer
                Thumbprint = $certificate.Thumbprint
                NotBefore = $certificate.NotBefore
                NotAfter = $certificate.NotAfter
                HasPrivateKey = [bool]$certificate.HasPrivateKey
                EnhancedKeyUsageOids = @($certificate.EnhancedKeyUsageList | ForEach-Object { "$($_.ObjectId)" })
            }
        }
    }
}

$inventory = & $addProbe 'LogInventory' {
    $directories = @((Join-Path $env:windir 'Temp'))
    foreach ($entry in @($installation.Data)) {
        if ($entry.Name -eq 'LogDirectory') { $directories += $entry.Value }
        else { $directories += (Join-Path $entry.Value 'Logs') }
    }
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed -or -not $drive.IsReady) { continue }
        foreach ($suffix in @('SMS\Logs', 'SMS_CCM\Logs', 'ConfigMgr\Logs', 'SMS_SRSRP\Logs',
                'Program Files\SMS_CCM\Logs', 'Program Files\SMS_SRSRP\Logs',
                'Program Files\Microsoft Configuration Manager\Logs')) {
            $directories += (Join-Path $drive.RootDirectory.FullName $suffix)
        }
    }
    foreach ($directory in @($directories | Sort-Object -Unique)) {
        try {
            if (-not (Test-Path -LiteralPath $directory -PathType Container -ErrorAction Stop)) { continue }
            Get-ChildItem -LiteralPath $directory -File -ErrorAction Stop |
                Where-Object { $_.Name -match '^(mpMSI|mpsetup|mpcontrol|sitecomp|srsrp|smsdpprov|SMS_BOOTSTRAP)\.(log|lo_)$' } |
                Select-Object @{ Name = 'Path'; Expression = { $_.FullName } },
                    @{ Name = 'LengthBytes'; Expression = { $_.Length } }, LastWriteTimeUtc
        }
        catch { $collectionErrors.Add("Log directory '$directory': $($_.Exception.Message)") }
    }
}
if (-not $SiteServerOnly) {
    $null = & $addProbe 'MpSetupLogPresence' {
        $setupLogs = @($inventory.Data | Where-Object { $_.Path -match '\\(mpMSI|mpsetup)\.(log|lo_)$' })
        if (-not $setupLogs.Count) { throw 'No MP setup logs found. Inspect LogInventory and InstallationPaths.' }
        $setupLogs | Select-Object Path
    }
}
elseif (-not @($inventory.Data).Count) {
    $collectionErrors.Add('No expected site logs found. Inspect LogInventory and InstallationPaths.')
}
foreach ($file in @($inventory.Data | Sort-Object Path -Unique)) {
    $log = [ordered]@{
        Path = $file.Path
        OriginalLengthBytes = $file.LengthBytes
        LastWriteTimeUtc = $file.LastWriteTimeUtc
        CaptureMode = 'Full'
        Content = $null
        Error = $null
    }
    try {
        if ($file.LengthBytes -le 8MB) {
            $log.Content = [string](Get-Content -LiteralPath $file.Path -Raw -ErrorAction Stop)
        }
        else {
            $log.CaptureMode = 'Last6000Lines'
            $log.Content = (Get-Content -LiteralPath $file.Path -Tail 6000 -ErrorAction Stop) -join "`r`n"
        }
    }
    catch {
        $log.CaptureMode = 'Failed'
        $log.Error = "$($_.Exception.GetType().FullName): $($_.Exception.Message); FQID=$($_.FullyQualifiedErrorId)"
        $collectionErrors.Add("$($file.Path): $($log.Error)")
    }
    $logs.Add([pscustomobject]$log)
}

$evidence = [ordered]@{
    ComputerName = $env:COMPUTERNAME
    CollectedAt = [datetime]::UtcNow.ToString('o')
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    Is64BitProcess = [Environment]::Is64BitProcess
    SiteCode = $SiteCode
    SiteServerOnly = [bool]$SiteServerOnly
    Probes = $probes.ToArray()
    Logs = $logs.ToArray()
    CollectionErrors = $collectionErrors.ToArray()
    Note = 'Collection only; no service, IIS, certificate, or ConfigMgr configuration changes.'
}
$json = $evidence | ConvertTo-Json -Depth 16
if ($AsJson) { return $json }
if (-not $OutputPath) { $OutputPath = Join-Path $env:TEMP "$env:COMPUTERNAME-ManagementPointDiagnostics.json" }
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$json | Set-Content -LiteralPath $OutputPath -Encoding UTF8 -ErrorAction Stop
Write-Host "MP/site evidence saved to $OutputPath"
Get-Item -LiteralPath $OutputPath -ErrorAction Stop
