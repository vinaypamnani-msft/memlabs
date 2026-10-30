function Invoke-ReportingNetworkIdentity {
    param([Parameter(Mandatory)][pscredential]$Credential, [Parameter(Mandatory)][scriptblock]$Action)
    if (-not ('MemLabs.ReportingNetworkIdentity' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace MemLabs {
    public sealed class ReportingNetworkIdentity : IDisposable {
        [DllImport("advapi32.dll", EntryPoint="LogonUserW", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool LogonUser(string user, string domain, IntPtr password, int type, int provider, out IntPtr token);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool CloseHandle(IntPtr handle);
        private IntPtr token;
        private WindowsImpersonationContext context;
        public ReportingNetworkIdentity(string user, string domain, IntPtr password) {
            if (!LogonUser(user, domain, password, 9, 3, out token))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try { context = WindowsIdentity.Impersonate(token); }
            catch { CloseHandle(token); token = IntPtr.Zero; throw; }
        }
        public void Dispose() {
            try { if (context != null) { context.Undo(); context.Dispose(); context = null; } }
            finally {
                if (token != IntPtr.Zero) {
                    IntPtr current = token; token = IntPtr.Zero;
                    if (!CloseHandle(current)) throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
        }
    }
}
'@ -ErrorAction Stop
    }
    $password = [IntPtr]::Zero
    $identity = $null
    try {
        $userName = $Credential.UserName
        $domain = $null
        if ($userName.Contains('\')) { $parts = $userName.Split('\',2); $domain = $parts[0]; $userName = $parts[1] }
        $password = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Credential.Password)
        $identity = [MemLabs.ReportingNetworkIdentity]::new($userName, $domain, $password)
        & $Action
    }
    finally {
        try { if ($identity) { $identity.Dispose() } }
        finally { if ($password -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($password) } }
    }
}

function Copy-ReportingEvidenceFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][hashtable]$Budget,
        [long]$MaxFileBytes = 32MB,
        [long]$TailBytes = 8MB,
        [long]$MaxTotalBytes = 256MB,
        [switch]$RequireWholeFile
    )
    $inputStream = $null; $outputStream = $null; $created = $false
    $temporary = "$Destination.partial"
    try {
        $item = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse-point evidence is not followed: $Source" }
        $inputStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $length = $inputStream.Length
        $offset = 0L
        if ($length -gt $MaxFileBytes) {
            if ($RequireWholeFile) { throw "Whole-file evidence exceeds its $MaxFileBytes-byte limit ($length bytes): $Source" }
            $offset = [math]::Max(0L, $length - $TailBytes)
        }
        $bytes = $length - $offset
        if ($Budget.Bytes -lt 0 -or $bytes -gt $MaxTotalBytes - $Budget.Bytes) { throw "Evidence exceeds the $MaxTotalBytes-byte aggregate limit." }
        $inputStream.Position = $offset
        $outputStream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $created = $true
        $buffer = [byte[]]::new(65536)
        $remaining = $bytes
        while ($remaining -gt 0) {
            $read = $inputStream.Read($buffer, 0, [int][math]::Min($buffer.Length, $remaining))
            if ($read -eq 0) { throw "Evidence was truncated during the snapshot: $Source" }
            $outputStream.Write($buffer, 0, $read)
            $remaining -= $read
        }
        $outputStream.Flush()
        $outputStream.Dispose(); $outputStream = $null
        [IO.File]::Move($temporary, $Destination)
        $Budget.Bytes = [long]$Budget.Bytes + $bytes
        [pscustomobject]@{
            Source = $Source; Destination = $Destination; SourceBytes = $length; CopiedBytes = $bytes
            Offset = $offset; Truncated = ($offset -gt 0); SourceChanged = ($inputStream.Length -ne $length)
            LastWriteUtc = $item.LastWriteTimeUtc.ToString('o'); Status = 'Copied'
        }
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($created -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-ReportingFileLocations {
    param([string[]]$AdditionalPaths)
    $locations = [Collections.Generic.List[object]]::new()
    foreach ($drive in @('C','E','D','F','G','H','R','S')) {
        foreach ($relative in @(
                'PBIRS\PBIRS\LogFiles', 'PBIRS\PBIRS\ReportServer\LogFiles',
                'Program Files\Microsoft Power BI Report Server\PBIRS\LogFiles',
                'Program Files\Microsoft SQL Server Reporting Services\SSRS\LogFiles',
                'SMS_SRSRP\Logs', 'Program Files\SMS_SRSRP\Logs', 'SMS\Logs', 'ConfigMgr\Logs',
                'Program Files\Microsoft Configuration Manager\Logs'
            )) {
            $locations.Add([pscustomobject]@{ Path = "${drive}:\$relative"; Kind = 'ReportingLogs' })
        }
    }
    foreach ($relative in @('staging\DSC','staging','Windows\Temp')) {
        $locations.Add([pscustomobject]@{ Path = "C:\$relative"; Kind = 'SetupLogs' })
    }
    foreach ($path in @($AdditionalPaths | Where-Object { $_ -match '^[A-Za-z]:\\' } | Select-Object -Unique)) {
        $locations.Add([pscustomobject]@{ Path = $path; Kind = 'ReportingLogs' })
    }
    $locations.ToArray()
}

function Get-ReportingAdminSharePath {
    param([Parameter(Mandatory)][string]$Target,[Parameter(Mandatory)][string]$LocalPath)
    if ($Target -match '[\\/:*?"<>|]' -or $LocalPath -notmatch '^[A-Za-z]:\\') { throw 'Reporting admin-share paths require a server name/IP and an absolute drive path.' }
    $normalized = [IO.Path]::GetFullPath($LocalPath)
    "\\$Target\$($normalized.Substring(0,1))`$$($normalized.Substring(2))"
}

function Save-ReportingSmbEvidence {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$Prefix,
        [Parameter(Mandatory)][string]$ManifestPath,
        [string[]]$AdditionalPaths,
        [switch]$AdditionalOnly
    )
    $manifest = [ordered]@{
        VMName = $VMName; Target = $Target; Method = 'SMB'; Status = 'Running'
        CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        Files = @(); Missing = @(); Errors = @(); BrowserVersions = @(); SafeConfiguration = @()
    }
    Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
    Invoke-ReportingNetworkIdentity -Credential $Credential -Action {
        $budget = @{ Bytes = 0L }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $shares = @{}
        $locations = if ($AdditionalOnly) {
            @($AdditionalPaths | Select-Object -Unique | ForEach-Object { [pscustomobject]@{Path=$_;Kind='ReportingLogs'} })
        }
        else { @(Get-ReportingFileLocations -AdditionalPaths $AdditionalPaths) }
        foreach ($location in $locations) {
            $path = $location.Path
            $drive = $path.Substring(0,1)
            if (-not $shares.ContainsKey($drive)) {
                try {
                    $null = Get-Item -LiteralPath (Get-ReportingAdminSharePath -Target $Target -LocalPath "${drive}:\") -ErrorAction Stop
                    $shares[$drive] = $true
                }
                catch {
                    $shares[$drive] = $false
                    $manifest.Errors += "Admin share '$drive`$': $($_.Exception.Message)"
                    Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
                }
            }
            if (-not $shares[$drive]) { continue }
            $remote = Get-ReportingAdminSharePath -Target $Target -LocalPath $path
            try {
                $directory = Get-Item -LiteralPath $remote -Force -ErrorAction Stop
                if ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse-point evidence directory is not followed: $path" }
                $files = @(Get-ChildItem -LiteralPath $remote -File -ErrorAction Stop |
                        Where-Object {
                            if ($location.Kind -eq 'SetupLogs') { return $_.Name -match '^(DSC_Log|InstallCMLog|PBI|ConfigMgrSetup|srsrp|srsrpsetup).*\.(log|lo_)$' }
                            $_.Name -match '(?i)^(srsrp|srsrpsetup|sitecomp|ReportServerService|ReportingServicesService|RSPortal|Microsoft\.ReportingServices\.Portal|PowerBI|RSHosting|ReportServerWebApp).*\.(log|lo_)$|^ERRORLOG(\.\d+)?$|^SQLAGENT\.OUT$'
                        } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 12)
                foreach ($file in $files) {
                    if (-not $seen.Add($file.FullName)) { continue }
                    $suffix = (Get-ReportingSourceHash -Source $file.FullName).Substring(0,12)
                    $destination = Join-Path $LogDirectory "$Prefix-$VMName-$suffix-$($file.Name)"
                    $manifest['PendingFile'] = [pscustomobject]@{ Source=$file.FullName; Destination=$destination; SourceBytes=$file.Length }
                    Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
                    try {
                        $manifest.Files += Copy-ReportingEvidenceFile -Source $file.FullName -Destination $destination -Budget $budget
                    }
                    catch { $manifest.Errors += "Copy '$path\$($file.Name)': $($_.Exception.Message)" }
                    $manifest.PendingFile = $null
                    Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
                }
            }
            catch [Management.Automation.ItemNotFoundException] { $manifest.Missing += $path }
            catch { $manifest.Errors += "Read '$path': $($_.Exception.Message)" }
            Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
        }
        if (-not $AdditionalOnly) {
            foreach ($relative in @(
                    'Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
                    'Program Files\Microsoft\Edge\Application\msedge.exe'
                )) {
                try {
                    $path = Get-ReportingAdminSharePath -Target $Target -LocalPath "C:\$relative"
                    $item = Get-Item -LiteralPath $path -ErrorAction Stop
                    $manifest.BrowserVersions += [pscustomobject]@{ Path = "C:\$relative"; Version = $item.VersionInfo.ProductVersion; Source = 'SMB' }
                }
                catch [Management.Automation.ItemNotFoundException] { $manifest.Missing += "C:\$relative" }
                catch { $manifest.Errors += "Browser version '$relative': $($_.Exception.Message)" }
            }
            foreach ($relative in @(
                    'PBIRS\PBIRS\ReportServer\RSReportServer.config',
                    'Program Files\Microsoft Power BI Report Server\PBIRS\ReportServer\RSReportServer.config',
                    'Program Files\Microsoft SQL Server Reporting Services\SSRS\ReportServer\RSReportServer.config'
                )) {
                $reader = $null
                try {
                    $settings = [Xml.XmlReaderSettings]::new()
                    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
                    $settings.XmlResolver = $null
                    $reader = [Xml.XmlReader]::Create((Get-ReportingAdminSharePath -Target $Target -LocalPath "C:\$relative"), $settings)
                    $xml = [Xml.XmlDocument]::new(); $xml.XmlResolver = $null; $xml.Load($reader)
                    $values = @($xml.SelectNodes('//InstanceId|//URLReservations/Application/Name|//URLReservations/Application/VirtualDirectory|//URLReservations/Application/URLs/URL/UrlString') |
                            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Value = $_.InnerText } })
                    $manifest.SafeConfiguration += [pscustomobject]@{ Path = "C:\$relative"; Values = $values }
                }
                catch [IO.FileNotFoundException] { $manifest.Missing += "C:\$relative" }
                catch [IO.DirectoryNotFoundException] { $manifest.Missing += "C:\$relative" }
                catch { $manifest.Errors += "Read safe report configuration '$relative': $($_.Exception.Message)" }
                finally { if ($reader) { $reader.Dispose() } }
            }
            foreach ($relative in @('ProgramData\Microsoft\Windows\WER\ReportArchive','ProgramData\Microsoft\Windows\WER\ReportQueue')) {
                try {
                    $directory = Get-ReportingAdminSharePath -Target $Target -LocalPath "C:\$relative"
                    $folders = @(Get-ChildItem -LiteralPath $directory -Directory -ErrorAction Stop |
                            Where-Object Name -Match '(?i)powershell|pwsh|wsmprovhost|vmicvmsession|ReportingServicesService|RSHostingService' |
                            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 6)
                    foreach ($folder in $folders) {
                        $source = Join-Path $folder.FullName 'Report.wer'
                        $suffix = (Get-ReportingSourceHash $source).Substring(0,12)
                        $destination = Join-Path $LogDirectory "$Prefix-$VMName-$suffix-Report.wer"
                        $manifest.PendingFile = [pscustomobject]@{Source=$source;Destination=$destination;SourceBytes=$null}
                        Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
                        try { $manifest.Files += Copy-ReportingEvidenceFile -Source $source -Destination $destination -Budget $budget -MaxFileBytes 1MB -RequireWholeFile }
                        catch { $manifest.Errors += "WER report '$source': $($_.Exception.Message)" }
                        $manifest.PendingFile = $null
                        Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
                    }
                }
                catch [Management.Automation.ItemNotFoundException] { $manifest.Missing += $relative }
                catch { $manifest.Errors += "WER report discovery '$relative': $($_.Exception.Message)" }
            }
            foreach ($name in @('Application','System','Microsoft-Windows-PowerShell%4Operational','Microsoft-Windows-Windows Defender%4Operational')) {
                $source = Get-ReportingAdminSharePath -Target $Target -LocalPath "C:\Windows\System32\winevt\Logs\$name.evtx"
                try {
                    $destination = Join-Path $LogDirectory "$Prefix-$VMName-$name.evtx"
                    $manifest.PendingFile = [pscustomobject]@{ Source=$source; Destination=$destination; SourceBytes=$null }
                    Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
                    $snapshot = Copy-ReportingEvidenceFile -Source $source -Destination $destination -Budget $budget -MaxFileBytes 64MB -RequireWholeFile
                    $snapshot | Add-Member NoteProperty Kind 'LiveEventLogSnapshot'
                    $snapshot | Add-Member NoteProperty Validation 'Live byte snapshot; filtered native event reads are collected independently.'
                    $manifest.Files += $snapshot
                }
                catch { $manifest.Errors += "Live EVTX '$name': $($_.Exception.Message) (filtered RPC event capture is attempted separately)" }
                $manifest.PendingFile = $null
                Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
            }
        }
    }
    $manifest.Status = if ($manifest.Files.Count -gt 0) { 'Captured' } else { 'Unavailable' }
    Write-MemLabsProcessProgress -Path $ManifestPath -Record $manifest
    [pscustomobject]$manifest
}

function Get-ReportingRpcEvidence {
    param([string]$Target, [string]$VMName, [pscredential]$Credential, [string]$CheckpointPath, [string]$ExpectedDomain)
    $report = [ordered]@{
        ComputerName = $VMName; Method = 'DCOM/RPC'; Target = $Target; Status = 'Running'
        OperatingSystem = $null; Services = @(); Browsers = @(); ReportServerConfiguration = @(); Events = @(); Errors = @()
    }
    if ($CheckpointPath) { Write-MemLabsProcessProgress -Path $CheckpointPath -Record $report }
    foreach ($query in @(
            @{ Class = 'Win32_ComputerSystem'; Kind = 'Identity' },
            @{ Class = 'Win32_OperatingSystem'; Kind = 'OperatingSystem' },
            @{ Class = 'Win32_Service'; Kind = 'Services' }
        )) {
        try {
            $arguments = @{ Class = $query.Class; ErrorAction = 'Stop'; Authentication='PacketPrivacy'; Impersonation='Impersonate' }
            if ($Target -notin @('localhost','.',$env:COMPUTERNAME)) { $arguments.ComputerName = $Target }
            if ($Credential) { $arguments.Credential = $Credential }
            if ($query.Kind -eq 'Services') { $arguments.Filter = "Name='PowerBIReportServer' OR Name='SQLServerReportingServices' OR Name LIKE 'ReportServer%' OR Name='MSSQLSERVER' OR Name LIKE 'MSSQL`$%' OR Name='SQLSERVERAGENT' OR Name='edgeupdate' OR Name='edgeupdatem'" }
            $rows = @(Get-WmiObject @arguments)
            switch ($query.Kind) {
                'Identity' {
                    if ($rows.Count -ne 1 -or $rows[0].Name -ine $VMName -or ($ExpectedDomain -and $rows[0].Domain -ine $ExpectedDomain)) {
                        $report['IdentityVerified'] = $false
                        throw "RPC target identity does not match '$VMName'."
                    }
                    $report['IdentityVerified'] = $true
                }
                'OperatingSystem' { $report.OperatingSystem = $rows | Select-Object Caption, Version, BuildNumber, LastBootUpTime, FreePhysicalMemory, TotalVisibleMemorySize }
                'Services' { $report.Services = @($rows | Select-Object Name, State, StartMode, PathName) }
            }
        }
        catch { $report.Errors += "$($query.Kind): $($_.Exception.Message)" }
        if ($CheckpointPath) { Write-MemLabsProcessProgress -Path $CheckpointPath -Record $report }
        if ($query.Kind -eq 'Identity' -and $report.Contains('IdentityVerified') -and -not $report.IdentityVerified) {
            $report.Status = 'IdentityMismatch'
            return [pscustomobject]$report
        }
    }
    try {
        $root = 'root\Microsoft\SqlServer\ReportServer'
        $arguments = @{ ComputerName = $Target; Namespace = $root; Class = '__NAMESPACE'; ErrorAction = 'Stop'; Authentication='PacketPrivacy'; Impersonation='Impersonate' }
        if ($Credential) { $arguments.Credential = $Credential }
        foreach ($instance in @(Get-WmiObject @arguments)) {
            $arguments.Namespace = "$root\$($instance.Name)"
            foreach ($version in @(Get-WmiObject @arguments | Where-Object Name -Match '^v\d+$')) {
                $configurationArguments = $arguments.Clone()
                $configurationArguments.Namespace = "$root\$($instance.Name)\$($version.Name)\Admin"
                $configurationArguments.Class = 'MSReportServer_ConfigurationSetting'
                $report.ReportServerConfiguration += @(Get-WmiObject @configurationArguments |
                        Select-Object InstanceName, Version, IsInitialized, DatabaseServerName, DatabaseName, VirtualDirectoryReportServer, VirtualDirectoryReportManager)
                if ($CheckpointPath) { Write-MemLabsProcessProgress -Path $CheckpointPath -Record $report }
            }
        }
    }
    catch { $report.Errors += "Report Server WMI: $($_.Exception.Message)" }
    foreach ($path in @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe','C:\Program Files\Microsoft\Edge\Application\msedge.exe')) {
        try {
            $arguments = @{ Class='Win32_DataFile'; Filter="Name='$($path.Replace('\','\\'))'"; ErrorAction='Stop'; Authentication='PacketPrivacy'; Impersonation='Impersonate' }
            if ($Target -notin @('localhost','.',$env:COMPUTERNAME)) { $arguments.ComputerName=$Target }
            if ($Credential) { $arguments.Credential=$Credential }
            foreach ($file in @(Get-WmiObject @arguments)) { $report.Browsers += [pscustomobject]@{ Path=$path; Version=$file.Version; Source='NativeWMI' } }
        }
        catch { $report.Errors += "Browser version '$path': $($_.Exception.Message)" }
        if ($CheckpointPath) { Write-MemLabsProcessProgress -Path $CheckpointPath -Record $report }
    }
    foreach ($log in @('Application','System','Microsoft-Windows-Windows Defender/Operational')) {
        try {
            $arguments = @{ FilterHashtable = @{
                    LogName = $log; StartTime = (Get-Date).AddHours(-4); Level = @(1,2,3)
                }; MaxEvents = 30; ErrorAction = 'Stop' }
            if ($Target -notin @('localhost','.',$env:COMPUTERNAME)) { $arguments.ComputerName = $Target }
            if ($Credential) { $arguments.Credential = $Credential }
            $events = @(Get-WinEvent @arguments |
                    Select-Object TimeCreated, Id, ProviderName, @{ Name = 'Message'; Expression = { "$($_.Message)".Substring(0,[math]::Min(4000,"$($_.Message)".Length)) } })
            $report.Events += [pscustomobject]@{ LogName = $log; Available = $true; Events = $events }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $report.Events += [pscustomobject]@{ LogName = $log; Available = $true; Events = @() } }
            else { $report.Errors += "Event log '$log': $($_.Exception.Message)" }
        }
        if ($CheckpointPath) { Write-MemLabsProcessProgress -Path $CheckpointPath -Record $report }
    }
    $report.Status = if ($report.OperatingSystem) { 'Captured' } else { 'Partial' }
    if ($CheckpointPath) { Write-MemLabsProcessProgress -Path $CheckpointPath -Record $report }
    [pscustomobject]$report
}

function Get-ReportingSqlEvidence {
    param([string]$Server, [string]$Database, [string]$SiteCode, [pscredential]$Credential)
    $action = {
        $connectionString = New-ReportingSqlConnectionString -Server $Server -Database $Database
        $connection = [Data.SqlClient.SqlConnection]::new($connectionString)
        $command = $connection.CreateCommand()
        try {
            $command.CommandTimeout = 15
            $prefix = if ($SiteCode) { "/ConfigMgr_$SiteCode/" } else { '/ConfigMgr_' }
            $folder = if ($SiteCode) { "/ConfigMgr_$SiteCode" } else { $null }
            $command.CommandText = 'SELECT COUNT_BIG(*) FROM dbo.Catalog WHERE [Type] = 2 AND LEFT([Path], LEN(@Prefix)) = @Prefix'
            $null = $command.Parameters.Add('@Prefix',[Data.SqlDbType]::NVarChar,425); $command.Parameters['@Prefix'].Value = $prefix
            $connection.Open()
            $count = [long]$command.ExecuteScalar()
            $folderExists = $null
            if ($folder) {
                $command.CommandText = 'SELECT COUNT_BIG(*) FROM dbo.Catalog WHERE [Type] = 1 AND [Path] = @Folder'
                $null = $command.Parameters.Add('@Folder',[Data.SqlDbType]::NVarChar,425); $command.Parameters['@Folder'].Value = $folder
                $folderExists = ([long]$command.ExecuteScalar() -gt 0)
            }

            [pscustomobject]@{
                Server = $Server; Database = $Database; ExpectedFolder = $folder; FolderExists = $folderExists
                ReportCount = $count; VerificationSucceeded = $true
                Source = $(if ($Credential) { 'HostSQL' } else { 'GuestSQL' }); Error = $null
                CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
        finally { $command.Dispose(); $connection.Dispose() }
    }
    if ($Credential) { Invoke-ReportingNetworkIdentity -Credential $Credential -Action $action }
    else { & $action }
}

function Invoke-ReportingHostWorker {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][string]$PrimitiveSource,
        [ValidateRange(1,180)][int]$TimeoutSeconds = 45,
        [string]$CheckpointPath
    )
    $worker = {
        param($Operation, $Arguments, $HelperPath, $ProcessPath, $PrimitiveSource)
        $action = {
            param($Operation, $Arguments, $HelperPath, $ProcessPath, $PrimitiveSource)
            $ProgressPreference = 'SilentlyContinue'
            . $ProcessPath
            . $HelperPath
            . ([scriptblock]::Create($PrimitiveSource))
            switch ($Operation) {
                'Files' { Save-ReportingSmbEvidence @Arguments }
                'Inventory' { Get-ReportingRpcEvidence @Arguments }
                'Events' { Get-ReportingRemoteEvents @Arguments }
                'Sql' { Get-ReportingSqlEvidence @Arguments }
                'Web' {
                    $uri = [uri]$Arguments.Uri
                    switch ($Arguments.Kind) {
                        'Catalog' {
                            $proxy = $null
                            try {
                                $proxy = New-WebServiceProxy -Uri "$($uri.AbsoluteUri.TrimEnd('/'))/ReportService2010.asmx" `
                                    -Credential $Arguments.Credential -ErrorAction Stop
                                $proxy.Timeout = 20000
                                Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode $Arguments.SiteCode
                            }
                            finally { if ($proxy) { $proxy.Dispose() } }
                        }
                        'Portal' { Get-ReportingPortalEvidence -PortalUri ([uri]::new($uri,'/Reports/')) -Credential $Arguments.Credential `
                            -ArtifactDirectory $Arguments.ArtifactDirectory -ArtifactPrefix $Arguments.ArtifactPrefix }
                        'ReportServerPage' {
                            $page = Invoke-ReportingWebRequest -Uri $uri -Credential $Arguments.Credential -TimeoutSeconds 20
                            [pscustomobject]@{
                                StatusCode = [int]$page.StatusCode; HtmlLength = ([string]$page.Content).Length
                                HtmlExcerpt = ([string]$page.Content).Substring(0,[math]::Min(16384,([string]$page.Content).Length))
                            }
                        }

                    }
                }
                'WinRM' {
                    $session = $null
                    try {
                        $option = New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000
                        $session = New-PSSession -ComputerName $Arguments.Target -Credential $Arguments.Credential `
                            -Authentication Negotiate -SessionOption $option -ErrorAction Stop
                        Invoke-Command -Session $session -ScriptBlock ([scriptblock]::Create($Arguments.Probe)) `
                            -ArgumentList $Arguments.ProbeArguments -ErrorAction Stop
                    }
                    finally { if ($session) { Remove-PSSession -Session $session -ErrorAction Stop } }
                }
                default { throw "Unsupported reporting worker operation '$Operation'." }
            }
        }
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $session = $null
            try {
                $session = New-PSSession -UseWindowsPowerShell -ErrorAction Stop
                Invoke-Command -Session $session -ScriptBlock $action `
                    -ArgumentList $Operation, $Arguments, $HelperPath, $ProcessPath, $PrimitiveSource -ErrorAction Stop
            }
            finally { if ($session) { Remove-PSSession -Session $session -ErrorAction Stop } }
        }
        else { & $action $Operation $Arguments $HelperPath $ProcessPath $PrimitiveSource }
    }
    try {
        $result = Invoke-MemLabsBoundedPowerShell -ProbeScript $worker -Parameters @{
            Operation = $Operation; Arguments = $Parameters; HelperPath = $PSCommandPath
            ProcessPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'DSC\phases\ProcessFunctions.ps1')
            PrimitiveSource = $PrimitiveSource
        } -TimeoutSeconds $TimeoutSeconds
    }
    catch { $result = [pscustomobject]@{ Output = $null; Error = $_.Exception.ToString(); TimedOut = $false; ElapsedSeconds = $null } }
    if ($result.Error -and $CheckpointPath -and [IO.File]::Exists($CheckpointPath)) {
        try {
            $partial = [IO.File]::ReadAllText($CheckpointPath) | ConvertFrom-Json -ErrorAction Stop
            if ($Operation -eq 'Files' -and $partial.PendingFile.Destination) {
                $pendingPath = "$($partial.PendingFile.Destination).partial"
                $root = [IO.Path]::GetFullPath($Parameters.LogDirectory).TrimEnd('\') + '\'
                if ([IO.Path]::GetFullPath($pendingPath).StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -and [IO.File]::Exists($pendingPath)) {
                    $partial.Files = @($partial.Files) + @([pscustomobject]@{
                            Source=$partial.PendingFile.Source; Destination=$pendingPath; SourceBytes=$partial.PendingFile.SourceBytes
                            CopiedBytes=([IO.FileInfo]$pendingPath).Length; Status='AbortedPartial'; Complete=$false
                        })
                    $partial.Errors = @($partial.Errors) + @('The file worker ended while a copy was active; its partial bytes are retained and are not a complete log/event file.')
                }
            }
            $result | Add-Member NoteProperty PartialOutput $partial
        }
        catch { $result.Error += " Partial checkpoint could not be read: $($_.Exception.Message)" }
    }
    $result
}

function Get-ReportingAddressCandidates {
    param([string]$VMName, [object]$Note)
    $addresses = [Collections.Generic.List[string]]::new()
    try {
        foreach ($nic in @(Get-VMNetworkAdapter -VMName $VMName -ErrorAction Stop)) {
            foreach ($value in @($nic.IPAddresses)) {
                $parsed = $null
                if ([Net.IPAddress]::TryParse("$value",[ref]$parsed) -and $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                    "$parsed" -notmatch '^(127\.|169\.254\.|0\.)') { $addresses.Add("$parsed") }
            }
        }
    }
    catch { Write-Log "Reporting address lookup for '$VMName' failed: $($_.Exception.Message)" -Warning -LogOnly }
    $noteAddresses = if ($addresses.Count -eq 0) { @("$($Note.AssignedIP)","$($Note.LastKnownIP)") } else { @() }
    foreach ($value in @($noteAddresses) + @("$VMName.$($Note.domain)",$VMName)) {
        if (-not [string]::IsNullOrWhiteSpace($value)) { $addresses.Add($value) }
    }
    @($addresses | Select-Object -Unique -First 4)
}

function Get-ReportingCollectionTargets {
    param([string]$VMName, [object]$Note, [string]$SiteCode)
    $targets = [Collections.Generic.List[object]]::new()
    $sqlNames = @($VMName,$Note.OtherNode) | Where-Object { $_ }
    $targets.Add([pscustomobject]@{ VMName = $VMName; Note = $Note; Kind = 'ReportingServer'; Addresses = @(Get-ReportingAddressCandidates $VMName $Note) })
    try {
        foreach ($vm in @(Get-VM -ErrorAction Stop)) {
            if ($vm.Name -ieq $VMName) { continue }
            if (-not $vm.Notes) { continue }
            try { $candidate = $vm.Notes | ConvertFrom-Json -ErrorAction Stop }
            catch { Write-Log "Ignoring non-MemLabs VM note for '$($vm.Name)' during reporting discovery: $($_.Exception.Message)" -Warning -LogOnly; continue }
            if ($candidate.domain -ine $Note.domain -or $candidate.role -notin @('Primary','CAS')) { continue }
            if (($SiteCode -and $candidate.siteCode -ieq $SiteCode) -or ($candidate.remoteSQLVM -and $candidate.remoteSQLVM -in $sqlNames)) {
                $targets.Add([pscustomobject]@{
                        VMName = $vm.Name; Note = $candidate; Kind = 'SiteServer'
                        Addresses = @(Get-ReportingAddressCandidates $vm.Name $candidate)
                    })
            }
        }
    }
    catch { Write-Log "Reporting owning-site discovery failed: $($_.Exception.Message)" -Warning -LogOnly }
    $targets.ToArray()
}

function Invoke-ReportingGuestAlternative {
    param(
        [string]$VMName, [string]$Domain, [string[]]$Addresses, [pscredential]$Credential,
        [scriptblock]$Probe, [object[]]$ProbeArguments, [string]$PrimitiveSource,
        [string]$Name, [int]$TimeoutSeconds = 45, [switch]$SkipPowerShellDirect
    )
    $attempts = [Collections.Generic.List[object]]::new()
    try {
        if ($SkipPowerShellDirect) { throw 'PowerShell Direct skipped after a previous broken channel for this VM.' }
        $result = Invoke-VmCommand -VmName $VMName -VmDomainName $Domain -ScriptBlock $Probe `
            -ArgumentList $ProbeArguments -DisplayName "Reporting isolated $Name" -AsJob -TimeoutSeconds $TimeoutSeconds `
            -SessionMaxRetries 1 -RequireDomainIdentity -FailOnRemoteError -SuppressLog
        if ($result.CommandResult -and -not $result.ScriptBlockFailed -and $null -ne $result.ScriptBlockOutput) {
            return [pscustomobject]@{ Output = $result.ScriptBlockOutput; Method = 'PowerShellDirect'; Attempts = $attempts.ToArray(); Error = $null }
        }
        $detail = if ($result.ErrorDetails) { $result.ErrorDetails -join '; ' } else { 'Guest call returned no verified result.' }
        $attempts.Add([pscustomobject]@{ Method = 'PowerShellDirect'; Error = $detail; TimedOut = $result.TimedOut; ChannelBroken = $result.ChannelBroken })
    }
    catch { $attempts.Add([pscustomobject]@{ Method = 'PowerShellDirect'; Error = $_.Exception.Message }) }
    foreach ($address in @($Addresses | Sort-Object { $_ -match '^\d+\.' } | Select-Object -Unique -First 2)) {
        $result = Invoke-ReportingHostWorker -Operation WinRM -Parameters @{
            Target = $address; Credential = $Credential; Probe = $Probe.ToString(); ProbeArguments = $ProbeArguments
        } -PrimitiveSource $PrimitiveSource -TimeoutSeconds $TimeoutSeconds
        if (-not $result.Error -and $null -ne $result.Output) {
            return [pscustomobject]@{ Output = $result.Output; Method = 'WinRM'; Attempts = $attempts.ToArray(); Error = $null }
        }
        $attempts.Add([pscustomobject]@{ Method = 'WinRM'; Target = $address; Error = $result.Error; TimedOut = $result.TimedOut })
    }
    [pscustomobject]@{ Output = $null; Method = $null; Attempts = $attempts.ToArray(); Error = "No transport completed '$Name'." }
}

function Save-ReportingHostCheckpoint {
    param([Parameter(Mandatory)][Collections.IDictionary]$Report, [Parameter(Mandatory)][string]$Path)
    $Report.CollectedAt = [DateTime]::UtcNow.ToString('o')
    Write-MemLabsProcessProgress -Path $Path -Record $Report
    Write-Progress -Activity "$($Report.ComputerName) reporting diagnostics" -Status "$($Report.CurrentStage)" -PercentComplete -1
}

function Add-ReportingHostAttempt {
    param($Report, [string]$Name, [string]$Method, [string]$Target, $Result)
    $Report.Attempts += [pscustomobject]@{
        Name = $Name; Method = $Method; Target = $Target
        Succeeded = (-not $Result.Error -and $null -ne $Result.Output)
        TimedOut = $Result.TimedOut; ElapsedSeconds = $Result.ElapsedSeconds; Error = $Result.Error
    }
}

function Invoke-ReportingHostCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)]$Note,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string]$CollectorSource,
        [Parameter(Mandatory)][string]$ProcessSource,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$SiteCode,
        [uri]$ReportServerUri,
        [switch]$AsJson
    )
    $logDirectory = Split-Path $TargetPath -Parent
    $null = New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop
    $id = [guid]::NewGuid().ToString('N')
    $prefix = "$VMName-Reporting-$id"
    $checkpoint = Join-Path $logDirectory "$prefix.partial.json"
    $primitiveSource = ''
    foreach ($name in @('Get-ReportingSourceHash','New-ReportingSqlConnectionString','Invoke-ReportingWebRequest','Get-ReportingCatalogEvidence','Get-ReportingPortalEvidence')) {
        $definition = Get-Command $name -CommandType Function -ErrorAction Stop
        $primitiveSource += "function $name { $($definition.Definition) }`n"
    }
    $helperSource = Get-Content -LiteralPath $PSCommandPath -Raw -ErrorAction Stop
    $guestSource = "$ProcessSource`n$primitiveSource`n$helperSource"
    $transport = Get-Command Invoke-VmCommand -CommandType Function -ErrorAction Stop
    $report = [ordered]@{
        SchemaVersion = 2; ComputerName = $VMName; SiteCode = $SiteCode; CollectedAt = [DateTime]::UtcNow.ToString('o')
        CollectionStatus = 'Running'; CollectionFailed = $false
        HostCollection = [pscustomobject]@{
            InvocationId = $id; StartedAt = [DateTime]::UtcNow.ToString('o'); HostPowerShellVersion = $PSVersionTable.PSVersion.ToString()
            CollectorSourceHash = Get-ReportingSourceHash $CollectorSource
            TransportSourceHash = Get-ReportingSourceHash $transport.Definition
            WorkerSourceHash = Get-ReportingSourceHash $ProcessSource
            HostHelperSourceHash = Get-ReportingSourceHash $helperSource
            CheckpointPath = $checkpoint
        }
        CurrentStage = 'Planning'; Attempts = @(); FileManifests = @(); RawFiles = @()
        OperatingSystem = $null; Services = @(); Browsers = @(); EdgeUpdateTasks = @()
        ReportServerConfiguration = @(); Endpoints = @(); SqlCatalog = @(); Logs = @()
        NativeEvents = @(); CollectionErrors = @(); Warnings = @()
        Note = 'Raw file capture precedes guest PowerShell. No VM, service, firewall, DNS, trust, or database configuration is changed.'
    }
    Save-ReportingHostCheckpoint $report $checkpoint
    try {
        $domain = "$($Note.domain)"
        $networkCredential = $Credential
        if ($Credential.UserName -notmatch '[\\@]') {
            $networkCredential = [pscredential]::new("$($Credential.UserName)@$domain",$Credential.Password)
        }
        $targets = @(Get-ReportingCollectionTargets -VMName $VMName -Note $Note -SiteCode $SiteCode)
        if (-not $SiteCode) {
            $owners = @($targets | Where-Object Kind -eq 'SiteServer' | ForEach-Object { $_.Note.siteCode } | Where-Object { $_ } | Select-Object -Unique)
            if ($owners.Count -eq 1) { $SiteCode = "$($owners[0])"; $report.SiteCode = $SiteCode }
        }
        if ($targets.Count -eq 1 -and $Note.role -notin @('Primary','CAS')) { $report.Warnings += 'Owning site server could not be resolved from Hyper-V notes; reporting-VM evidence is still collected.' }
        $report.CurrentStage = 'Copying raw files before guest PowerShell'
        Save-ReportingHostCheckpoint $report $checkpoint
        foreach ($target in $targets) {
            foreach ($address in $target.Addresses) {
                $manifestPath = Join-Path $logDirectory "$prefix-$($target.VMName)-files-$($report.Attempts.Count).json"
                $result = Invoke-ReportingHostWorker -Operation Files -Parameters @{
                    Target = $address; VMName = $target.VMName; Credential = $networkCredential
                    LogDirectory = $logDirectory; Prefix = $prefix; ManifestPath = $manifestPath
                } -PrimitiveSource $primitiveSource -TimeoutSeconds 30 -CheckpointPath $manifestPath
                Add-ReportingHostAttempt $report 'PrePowerShellFiles' 'SMB' $address $result
                $manifest = if ($result.Output) { $result.Output } elseif ($result.PartialOutput) { $result.PartialOutput } else { $null }
                $report.FileManifests += [pscustomobject]@{ VMName = $target.VMName; Path = $manifestPath; Error = $result.Error }
                if ($manifest) {
                    $report.RawFiles += @($manifest.Files | Where-Object { $_.Destination })
                    if ($target.Kind -eq 'ReportingServer') { $report.Browsers += @($manifest.BrowserVersions) }
                }
                Save-ReportingHostCheckpoint $report $checkpoint
                if ($manifest -and @($manifest.Files).Count -gt 0) { break }
            }
        }
        if (-not $AsJson) { Write-Host "Initial raw file capture retained $($report.RawFiles.Count) file(s). Durable checkpoint: $checkpoint" }
        $reportingTarget = $targets | Where-Object Kind -eq 'ReportingServer' | Select-Object -First 1
        $addresses = @($reportingTarget.Addresses)
        $brokenDirect = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $report.CurrentStage = 'Native RPC inventory and events'
        Save-ReportingHostCheckpoint $report $checkpoint
        foreach ($address in $addresses | Select-Object -First 2) {
            $inventoryPath = Join-Path $logDirectory "$prefix-native-$($report.Attempts.Count).json"
            $result = Invoke-ReportingHostWorker -Operation Inventory -Parameters @{
                Target = $address; VMName = $VMName; Credential = $networkCredential; CheckpointPath = $inventoryPath; ExpectedDomain = $domain
            } -PrimitiveSource $primitiveSource -TimeoutSeconds 60 -CheckpointPath $inventoryPath
            Add-ReportingHostAttempt $report 'Inventory' 'DCOM/RPC' $address $result
            $inventory = if ($result.Output) { $result.Output } elseif ($result.PartialOutput) { $result.PartialOutput } else { $null }
            if ($inventory -and $inventory.IdentityVerified) {
                $report.OperatingSystem = $inventory.OperatingSystem; $report.Services = @($inventory.Services)
                $report.ReportServerConfiguration = @($inventory.ReportServerConfiguration); $report.NativeEvents = @($inventory.Events)
                $report.Browsers += @($inventory.Browsers)
            }
            Save-ReportingHostCheckpoint $report $checkpoint
            if ($report.OperatingSystem -and $report.ReportServerConfiguration.Count -gt 0) { break }
        }
        $knownPaths = @(Get-ReportingFileLocations | ForEach-Object Path)
        $additionalPaths = @(
            foreach ($service in $report.Services) {
                if ($service.PathName -match '^\s*"?([A-Za-z]:\\.+?\.exe)(?:"|\s|$)') {
                    $directory = Split-Path $Matches[1] -Parent
                    foreach ($path in @("$directory\LogFiles","$directory\Logs","$(Split-Path $directory -Parent)\LogFiles","$(Split-Path $directory -Parent)\Log")) {
                        if ($path -notin $knownPaths) { $path }
                    }
                }
            }
        ) | Select-Object -Unique
        if ($additionalPaths.Count -gt 0 -and $addresses.Count -gt 0) {
            $manifestPath = Join-Path $logDirectory "$prefix-discovered-files.json"
            $result = Invoke-ReportingHostWorker -Operation Files -Parameters @{
                Target=$addresses[0]; VMName=$VMName; Credential=$networkCredential; LogDirectory=$logDirectory
                Prefix="$prefix-discovered"; ManifestPath=$manifestPath; AdditionalPaths=$additionalPaths; AdditionalOnly=$true
            } -PrimitiveSource $primitiveSource -TimeoutSeconds 30 -CheckpointPath $manifestPath
            Add-ReportingHostAttempt $report 'DiscoveredFilePaths' 'SMB' $addresses[0] $result
            $report.FileManifests += [pscustomobject]@{ VMName=$VMName; Path=$manifestPath; Error=$result.Error }
            $manifest = if ($result.Output) { $result.Output } elseif ($result.PartialOutput) { $result.PartialOutput } else { $null }
            if ($manifest) { $report.RawFiles += @($manifest.Files | Where-Object Destination) }
            Save-ReportingHostCheckpoint $report $checkpoint
        }
        if ($report.NativeEvents.Count -eq 0 -and $addresses.Count -gt 0) {
            $eventPath = Join-Path $logDirectory "$prefix-native-events.json"
            $result = Invoke-ReportingHostWorker -Operation Events -Parameters @{
                Target = $addresses[0]; Credential = $networkCredential
                StartedAt = $report.HostCollection.StartedAt; CheckpointPath = $eventPath
            } -PrimitiveSource $primitiveSource -TimeoutSeconds 35 -CheckpointPath $eventPath
            Add-ReportingHostAttempt $report 'EventLogs' 'NativeEventRPC' $addresses[0] $result
            if ($result.Output) { $report.NativeEvents += $result.Output }
            elseif ($result.PartialOutput) { $report.NativeEvents += $result.PartialOutput }
            Save-ReportingHostCheckpoint $report $checkpoint
        }
        $report.CurrentStage = 'Independent host HTTP and SOAP probes'
        Save-ReportingHostCheckpoint $report $checkpoint
        $uris = if ($ReportServerUri) { @($ReportServerUri.AbsoluteUri) } else {
            $values = @("https://$VMName.$domain/ReportServer","http://$VMName.$domain/ReportServer")
            $ip = $addresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
            if ($ip) { $values += "http://$ip/ReportServer" }
            $values
        }
        foreach ($uri in $uris) {
            $endpoint = [pscustomobject]@{
                Uri = $uri; Catalog = $null; CatalogError = $null; Portal = $null; PortalError = $null
                ReportServerPage = $null; ReportServerPageError = $null; Probes = @()
            }
            $report.Endpoints += $endpoint
            foreach ($kind in @('Catalog','ReportServerPage','Portal')) {
                $result = Invoke-ReportingHostWorker -Operation Web -Parameters @{
                    Kind = $kind; Uri = $uri; SiteCode = $SiteCode; Credential = $networkCredential
                    ArtifactDirectory = $logDirectory; ArtifactPrefix = "$prefix-$($report.Attempts.Count)"
                } -PrimitiveSource $primitiveSource -TimeoutSeconds 40
                Add-ReportingHostAttempt $report $kind 'HostHTTP' $uri $result
                if ($result.Error) { $endpoint."${kind}Error" = $result.Error }
                else { $endpoint.$kind = $result.Output }
                $endpoint.Probes += [pscustomobject]@{ Name = $kind; Method = 'HostHTTP'; TimedOut = $result.TimedOut; Error = $result.Error; ElapsedSeconds = $result.ElapsedSeconds }
                Save-ReportingHostCheckpoint $report $checkpoint
            }
        }
        $report.CurrentStage = 'Independent SQL catalog verification'
        Save-ReportingHostCheckpoint $report $checkpoint
        $sqlConfigurations = @($report.ReportServerConfiguration | Where-Object { $_.DatabaseServerName -and $_.DatabaseName })
        if ($sqlConfigurations.Count -eq 0 -and $Note.sqlVersion) {
            $server = "$VMName.$domain"
            if ($Note.sqlInstanceName -and $Note.sqlInstanceName -ne 'MSSQLSERVER') { $server += "\$($Note.sqlInstanceName)" }
            if ($Note.sqlPort -and "$($Note.sqlPort)" -ne '1433') { $server += ",$($Note.sqlPort)" }
            $sqlConfigurations = @([pscustomobject]@{ DatabaseServerName = $server; DatabaseName = 'ReportServer'; Source = 'VMNoteInference' })
        }
        foreach ($configuration in $sqlConfigurations | Select-Object -First 2) {
            $sqlTargets = @("$($configuration.DatabaseServerName)")
            $sqlHost = ($sqlTargets[0] -split '[\\,]')[0]
            if ($sqlHost -in @($VMName,"$VMName.$domain")) {
                $ip = $addresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
                if ($ip) { $sqlTargets += "$ip$($sqlTargets[0].Substring($sqlHost.Length))" }
            }
            foreach ($server in $sqlTargets | Select-Object -Unique) {
                $result = Invoke-ReportingHostWorker -Operation Sql -Parameters @{
                    Server = $server; Database = $configuration.DatabaseName; SiteCode = $SiteCode; Credential = $networkCredential
                } -PrimitiveSource $primitiveSource -TimeoutSeconds 35
                Add-ReportingHostAttempt $report 'SqlCatalog' 'HostSQL' $server $result
                if ($result.Error) { $report.SqlCatalog += [pscustomobject]@{ Server = $server; Database = $configuration.DatabaseName; ReportCount = $null; VerificationSucceeded = $false; Error = $result.Error } }
                else { $report.SqlCatalog += $result.Output }
                Save-ReportingHostCheckpoint $report $checkpoint
                if (-not $result.Error) { break }
            }
        }
        $report.CurrentStage = 'Isolated guest fallbacks'
        Save-ReportingHostCheckpoint $report $checkpoint
        if (-not $report.OperatingSystem -or $report.ReportServerConfiguration.Count -eq 0) {
            $probe = {
                param($Source, $ExpectedName, $ExpectedDomain)
                . ([scriptblock]::Create($Source))
                Get-ReportingRpcEvidence -Target localhost -VMName $ExpectedName -ExpectedDomain $ExpectedDomain
            }
            $fallback = Invoke-ReportingGuestAlternative -VMName $VMName -Domain $domain -Addresses $addresses -Credential $networkCredential `
                -Probe $probe -ProbeArguments $guestSource,$VMName,$domain -PrimitiveSource $primitiveSource -Name Inventory -TimeoutSeconds 50
            $report.Attempts += @($fallback.Attempts)
            if ($fallback.Attempts | Where-Object { $_.Method -eq 'PowerShellDirect' -and $_.ChannelBroken }) { $null = $brokenDirect.Add($VMName) }
            if ($fallback.Output -and $fallback.Output.IdentityVerified) {
                $report.OperatingSystem = $fallback.Output.OperatingSystem; $report.Services = @($fallback.Output.Services)
                $report.ReportServerConfiguration = @($fallback.Output.ReportServerConfiguration)
                $report.Browsers += @($fallback.Output.Browsers)
                $report.NativeEvents += @($fallback.Output.Events)
            }
            elseif ($fallback.Error) { $report.CollectionErrors += $fallback.Error }
            Save-ReportingHostCheckpoint $report $checkpoint
        }
        foreach ($endpoint in $report.Endpoints) {
            foreach ($kind in @('Catalog','ReportServerPage','Portal')) {
                if ($null -ne $endpoint.$kind -and -not $endpoint."${kind}Error") { continue }
                $probe = {
                    param($Source, $Kind, $Uri, $SiteCode)
                    $ProgressPreference = 'SilentlyContinue'
                    . ([scriptblock]::Create($Source))
                    $uriValue = [uri]$Uri
                    switch ($Kind) {
                        'Catalog' {
                            $proxy = $null
                            try {
                                $proxy = New-WebServiceProxy -Uri "$($uriValue.AbsoluteUri.TrimEnd('/'))/ReportService2010.asmx" -UseDefaultCredential -ErrorAction Stop
                                $proxy.Timeout = 20000
                                Get-ReportingCatalogEvidence -Proxy $proxy -SiteCode $SiteCode
                            }
                            finally { if ($proxy) { $proxy.Dispose() } }
                        }
                        'Portal' { Get-ReportingPortalEvidence -PortalUri ([uri]::new($uriValue,'/Reports/')) }
                        'ReportServerPage' {
                            $page = Invoke-ReportingWebRequest -Uri $uriValue -TimeoutSeconds 20
                            [pscustomobject]@{ StatusCode = [int]$page.StatusCode; HtmlLength = ([string]$page.Content).Length }
                        }
                    }
                }
                $fallback = Invoke-ReportingGuestAlternative -VMName $VMName -Domain $domain -Addresses $addresses -Credential $networkCredential `
                    -Probe $probe -ProbeArguments $guestSource,$kind,$endpoint.Uri,$SiteCode -PrimitiveSource $primitiveSource -Name $kind -TimeoutSeconds 40 `
                    -SkipPowerShellDirect:($brokenDirect.Contains($VMName))
                $report.Attempts += @($fallback.Attempts)
                if ($fallback.Attempts | Where-Object { $_.Method -eq 'PowerShellDirect' -and $_.ChannelBroken }) { $null = $brokenDirect.Add($VMName) }
                if (-not $fallback.Error -and $null -ne $fallback.Output) {
                    $endpoint.$kind = $fallback.Output; $endpoint."${kind}Error" = $null
                    $endpoint.Probes += [pscustomobject]@{ Name = $kind; Method = $fallback.Method; Error = $null }
                }
                Save-ReportingHostCheckpoint $report $checkpoint
            }
        }
        if (@($report.SqlCatalog | Where-Object VerificationSucceeded).Count -eq 0) {
            $authoritativeSql = @($report.ReportServerConfiguration | Where-Object { $_.DatabaseServerName -and $_.DatabaseName })
            if ($authoritativeSql.Count -gt 0) { $sqlConfigurations = $authoritativeSql }
            foreach ($configuration in $sqlConfigurations | Select-Object -First 1) {
                $probe = {
                    param($Source, $Server, $Database, $SiteCode)
                    . ([scriptblock]::Create($Source))
                    Get-ReportingSqlEvidence -Server $Server -Database $Database -SiteCode $SiteCode
                }
                $fallback = Invoke-ReportingGuestAlternative -VMName $VMName -Domain $domain -Addresses $addresses -Credential $networkCredential `
                    -Probe $probe -ProbeArguments $guestSource,$configuration.DatabaseServerName,$configuration.DatabaseName,$SiteCode `
                    -PrimitiveSource $primitiveSource -Name SqlCatalog -TimeoutSeconds 35 -SkipPowerShellDirect:($brokenDirect.Contains($VMName))
                $report.Attempts += @($fallback.Attempts)
                if ($fallback.Attempts | Where-Object { $_.Method -eq 'PowerShellDirect' -and $_.ChannelBroken }) { $null = $brokenDirect.Add($VMName) }
                if (-not $fallback.Error -and $fallback.Output) { $report.SqlCatalog += $fallback.Output }
                Save-ReportingHostCheckpoint $report $checkpoint
            }
        }
        foreach ($target in $targets) {
            if (@($report.RawFiles | Where-Object { $_.Source -like "\\*\*" -and $_.Source -match '\.(log|lo_)$' -and
                        $_.Status -ne 'AbortedPartial' -and $_.Destination -like "*-$($target.VMName)-*" }).Count -gt 0) { continue }
            $probe = { param($Source,$Paths); . ([scriptblock]::Create($Source)); Get-ReportingGuestLogEvidence -AdditionalPaths $Paths }
            $paths = if ($target.Kind -eq 'ReportingServer') { @($additionalPaths) } else { @() }
            $fallback = Invoke-ReportingGuestAlternative -VMName $target.VMName -Domain $domain -Addresses $target.Addresses -Credential $networkCredential `
                -Probe $probe -ProbeArguments @($guestSource,$paths) -PrimitiveSource $primitiveSource -Name LogFiles -TimeoutSeconds 40 `
                -SkipPowerShellDirect:($brokenDirect.Contains($target.VMName))
            $report.Attempts += @($fallback.Attempts)
            if ($fallback.Attempts | Where-Object { $_.Method -eq 'PowerShellDirect' -and $_.ChannelBroken }) { $null = $brokenDirect.Add($target.VMName) }
            if ($fallback.Output) {
                foreach ($file in @($fallback.Output.Files)) {
                    try {
                        if ($file.ContentBase64.Length -gt 2MB) { throw 'Guest log payload exceeds its bounded transfer size.' }
                        $bytes = [Convert]::FromBase64String($file.ContentBase64)
                        if ($bytes.Length -ne $file.CopiedBytes -or $bytes.Length -gt 1MB) { throw 'Guest log fallback returned an invalid byte count.' }
                        $suffix = (Get-ReportingSourceHash $file.Source).Substring(0,12)
                        $destination = Join-Path $logDirectory "$prefix-$($target.VMName)-$suffix-$([IO.Path]::GetFileName($file.Source))"
                        [IO.File]::WriteAllBytes("$destination.partial",$bytes)
                        [IO.File]::Move("$destination.partial",$destination)
                        $report.RawFiles += [pscustomobject]@{
                            Source = $file.Source; Destination = $destination; SourceBytes = $file.SourceBytes; Status='Copied'
                            CopiedBytes = $file.CopiedBytes; Truncated = $file.Truncated; Offset = $file.Offset; Method = $fallback.Method
                        }
                    }
                    catch { $report.CollectionErrors += "Persist fallback log '$($file.Source)': $($_.Exception.Message)" }
                    Save-ReportingHostCheckpoint $report $checkpoint
                }
            }
            Save-ReportingHostCheckpoint $report $checkpoint
        }
        if ($brokenDirect.Count -gt 0) {
            $report.CurrentStage = 'Refreshing native crash events after broken guest channels'
            Save-ReportingHostCheckpoint $report $checkpoint
            foreach ($target in $targets | Where-Object { $brokenDirect.Contains($_.VMName) }) {
                $eventPath = Join-Path $logDirectory "$prefix-$($target.VMName)-post-failure-events.json"
                $result = Invoke-ReportingHostWorker -Operation Events -Parameters @{
                    Target = $target.Addresses[0]; Credential = $networkCredential
                    StartedAt = $report.HostCollection.StartedAt; CheckpointPath = $eventPath
                } -PrimitiveSource $primitiveSource -TimeoutSeconds 35 -CheckpointPath $eventPath
                Add-ReportingHostAttempt $report 'PostFailureEvents' 'NativeEventRPC' $target.VMName $result
                if ($result.Output) { $report.NativeEvents += $result.Output }
                elseif ($result.PartialOutput) { $report.NativeEvents += $result.PartialOutput }
                Save-ReportingHostCheckpoint $report $checkpoint
            }
        }
        $catalogKnown = @($report.Endpoints | Where-Object { $_.Catalog -and -not $_.CatalogError }).Count -gt 0 -or
        @($report.SqlCatalog | Where-Object VerificationSucceeded).Count -gt 0
        $portalKnown = @($report.Endpoints | Where-Object { $_.Portal -and -not $_.PortalError }).Count -gt 0
        if (-not $catalogKnown) { $report.CollectionErrors += 'Report publication could not be measured through SOAP or SQL.' }
        if (-not $portalKnown) { $report.CollectionErrors += 'No transport returned portal evidence.' }
        if ($report.RawFiles.Count -eq 0) { $report.CollectionErrors += 'No raw guest log files were copied; see file manifests and transport attempts.' }
        elseif (@($report.RawFiles | Where-Object { $_.Source -match '\.(log|lo_)$' -and $_.Status -ne 'AbortedPartial' }).Count -eq 0) {
            $report.CollectionErrors += 'No complete/tail reporting log snapshot was copied; event or aborted-byte snapshots are retained separately.'
        }
        if (-not $report.OperatingSystem) { $report.CollectionErrors += 'Operating-system/inventory identity could not be verified through native or guest methods.' }
        if ($report.Browsers.Count -eq 0) { $report.Warnings += 'Installed browser version could not be read; browser-only blank-page compatibility is unverified.' }
        if ($report.ReportServerConfiguration.Count -eq 0) { $report.Warnings += 'Report Server WMI configuration is unavailable; any SQL target inference is recorded in its connection result.' }
        if (@($report.Attempts | Where-Object { $_.Error }).Count -gt 0) { $report.Warnings += 'One or more collection methods failed; consult Attempts for errors and successful alternative sources.' }
        $report.CollectionFailed = -not ($catalogKnown -and $portalKnown)
        $report.CollectionStatus = if ($report.CollectionErrors.Count -or $report.Warnings.Count) { 'Partial' } else { 'Complete' }
        $report.CurrentStage = 'Finished'
    }
    catch {
        $report.CollectionStatus = 'Partial'; $report.CollectionFailed = $true
        $report.CollectionErrors += "Unexpected collection error at '$($report.CurrentStage)': $($_.Exception.ToString())"
    }
    finally {
        Save-ReportingHostCheckpoint $report $checkpoint
        Write-Progress -Activity "$VMName reporting diagnostics" -Completed
    }
    $json = $report | ConvertTo-Json -Depth 14
    if ($AsJson) { return $json }
    if ($report.CollectionFailed) {
        $failurePath = [IO.Path]::ChangeExtension($TargetPath,"failure-$id.json")
        Write-MemLabsProcessProgress -Path $failurePath -Record $report
        throw "Reporting capture is partial; independent logs and checkpoints are retained. Evidence: $failurePath; checkpoint: $checkpoint"
    }
    Write-MemLabsProcessProgress -Path $TargetPath -Record $report
    if ($report.CollectionStatus -eq 'Partial') { Write-Warning "Reporting evidence is partial: $((@($report.CollectionErrors)+@($report.Warnings)) -join '; '). Checkpoint: $checkpoint" }
    Write-Host "Reporting evidence saved to $TargetPath; raw files: $($report.RawFiles.Count)."
    Get-Item -LiteralPath $TargetPath -ErrorAction Stop
}

function Get-ReportingGuestLogEvidence {
    param([string[]]$AdditionalPaths)
    $files = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[string]]::new()
    $missing = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($location in @(Get-ReportingFileLocations -AdditionalPaths $AdditionalPaths)) {
        if ($files.Count -ge 12) { break }
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $location.Path -File -ErrorAction Stop |
                        Where-Object Name -Match '^(srsrp|srsrpsetup|sitecomp|ReportServerService|ReportingServicesService|RSPortal|DSC_Log|InstallCMLog|PBI).*\.(log|lo_)$|^ERRORLOG(\.\d+)?$|^SQLAGENT\.OUT$' |
                        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 4)) {
                if ($files.Count -ge 12) { break }
                if (-not $seen.Add($file.FullName)) { continue }
                $stream = $null
                try {
                    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse-point log is not followed.' }
                    $stream = [IO.File]::Open($file.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,
                        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
                    $size = $stream.Length
                    $offset = [math]::Max(0L,$size - 1MB)
                    $stream.Position = $offset
                    $data = [byte[]]::new([int]($size - $offset))
                    $read = 0
                    while ($read -lt $data.Length) {
                        $count = $stream.Read($data,$read,$data.Length - $read)
                        if ($count -eq 0) { throw 'Log was truncated during fallback capture.' }
                        $read += $count
                    }
                    $files.Add([pscustomobject]@{
                            Source = $file.FullName; SourceBytes = $size; CopiedBytes = $data.Length
                            Truncated = ($offset -gt 0); Offset = $offset; ContentBase64 = [Convert]::ToBase64String($data)
                        })
                }
                catch { $errors.Add("Read '$($file.FullName)': $($_.Exception.Message)") }
                finally { if ($stream) { $stream.Dispose() } }
            }
        }
        catch [Management.Automation.ItemNotFoundException] { $missing.Add($location.Path) }
        catch { $errors.Add("Read '$($location.Path)': $($_.Exception.Message)") }
    }
    [pscustomobject]@{ Files = $files.ToArray(); Errors = $errors.ToArray(); Missing = $missing.ToArray(); Method = 'GuestPowerShellFallback' }
}

function Get-ReportingRemoteEvents {
    param([string]$Target,[pscredential]$Credential,[string]$StartedAt,[string]$CheckpointPath)
    $report = [ordered]@{
        Target = $Target; Method = 'NativeEventRPC'; CapturedAtUtc = [DateTime]::UtcNow.ToString('o')
        EventLogs = @(); Errors = @()
    }
    foreach ($query in @(
            @{ Name='Application'; Id=@(1000,1001,1026) },
            @{ Name='System'; Id=@(41,1074,2004,6008,7031,7034) },
            @{ Name='Microsoft-Windows-Windows Defender/Operational'; Id=@(1116,1117,1121,1122) }
        )) {
        try {
            $events = @(Get-WinEvent -ComputerName $Target -Credential $Credential -FilterHashtable @{
                    LogName=$query.Name; Id=$query.Id; StartTime=[DateTimeOffset]::Parse($StartedAt).UtcDateTime.AddMinutes(-2)
                } -MaxEvents 30 -ErrorAction Stop |
                    Select-Object TimeCreated,Id,ProviderName,@{Name='Message';Expression={"$($_.Message)".Substring(0,[math]::Min(4000,"$($_.Message)".Length))}})
            $report.EventLogs += [pscustomobject]@{ LogName=$query.Name; Available=$true; Events=$events }
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $report.EventLogs += [pscustomobject]@{ LogName=$query.Name; Available=$true; Events=@() } }
            else { $report.Errors += "$($query.Name): $($_.Exception.Message)" }
        }
        Write-MemLabsProcessProgress -Path $CheckpointPath -Record $report
    }
    [pscustomobject]$report
}
