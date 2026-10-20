<#
.SYNOPSIS
    Qualifies existing-site maintenance on explicitly identified disposable test VMs.
.DESCRIPTION
    Invoked by the pinned expansion runner. Recovery deliberately damages only the
    supplied VM identities. It never discovers a test target from an unrestricted
    domain or VM-name wildcard. A failed receipt retains the lab for diagnosis.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Preflight', 'Baseline', 'Postconditions', 'Recovery')][string]$Mode,
    [Parameter(Mandatory)][string]$ReceiptPath,
    [Parameter(Mandatory)][string]$MainRevision,
    [Parameter(Mandatory)][string]$DevelopRevision,
    [string]$TargetsPath,
    [string]$AdminCachePath,
    [string]$Family = '__revision__',
    [switch]$RequireCleanSource
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Common.MaintenanceQualification.ps1')
$script:MQReceipt = $null
$script:MQSource = $null
$script:MQReceiptWritable = $false
$script:MQTargets = @()
$script:MQRunId = [guid]::NewGuid().ToString('N')
$script:MQGuestRoot = "C:\staging\Fix\qualification\$script:MQRunId"

function Assert-MQTarget {
    param([Parameter(Mandatory)]$Target)
    $vm = Get-VM -Id ([guid]$Target.Id) -ErrorAction Stop
    if ("$($vm.Name)" -ine "$($Target.Name)") { throw "Qualification VM identity changed: $($Target.Name)/$($Target.Id)" }
    $note = $vm.Notes | ConvertFrom-Json -ErrorAction Stop
    if (-not $note.domain -or ($Target.Domain -and $note.domain -ine $Target.Domain)) {
        throw "Qualification domain identity changed on $($Target.Name)"
    }
    return $note
}

function Invoke-MQGuest {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$Arguments = @(),
        [int]$TimeoutSeconds = 180
    )
    $note = Assert-MQTarget -Target $Target
    $account = if ($note.adminName) { "$($note.adminName)" } elseif ($note.domainAdmin) { "$($note.domainAdmin)" } else { '' }
    if (-not $account) { throw "No setup administrator is recorded for scoped VM $($Target.Name)." }
    $request = [pscustomobject]@{ Name = $Target.Name; Script = $ScriptBlock.ToString(); Arguments = @($Arguments) }
    $command = {
        param($Request)
        $ErrorActionPreference = 'Stop'
        if ($env:COMPUTERNAME -ine $Request.Name) { throw 'Qualification connected to a different guest.' }
        try { & ([scriptblock]::Create($Request.Script)) @($Request.Arguments) }
        catch { throw "Guest qualification failed at $($_.ScriptStackTrace): $($_.Exception.Message)" }
    }
    $result = Invoke-VmCommand -VmName $Target.Name -VmDomainName $note.domain -VmDomainAccount $account `
        -RequireDomainIdentity -ScriptBlock $command -ArgumentList $request -AsJob -TimeoutSeconds $TimeoutSeconds `
        -FailOnRemoteError -SessionMaxRetries 1 -SuppressLog -DisplayName "Maintenance qualification $Mode"
    if (-not $result -or $result.ScriptBlockFailed) {
        throw "Qualification guest operation failed on $($Target.Name): $($result.ErrorDetails)"
    }
    return $result.ScriptBlockOutput
}

function Get-MQFixes {
    param($Target)
    $note = Assert-MQTarget -Target $Target
    return @(Get-VMFixes -VMName $Target.Name -VMNote $note -NewVM $false |
        Where-Object { $_.AppliesToThisVM -and $_.FixName -in @('Fix-ODBC18', 'Fix-Upgrade-Console', 'Fix-CMFullAdmin') })
}

function Clear-MQFixStamp {
    param($Target, [string]$FixName)
    $null = Assert-MQTarget -Target $Target
    $vm = Get-VM -Id ([guid]$Target.Id) -ErrorAction Stop
    $note = $vm.Notes | ConvertFrom-Json -ErrorAction Stop
    if ($note.appliedFixes -and $note.appliedFixes.PSObject.Properties[$FixName]) {
        $note.appliedFixes.PSObject.Properties.Remove($FixName)
        Set-VM -VM $vm -Notes ($note | ConvertTo-Json -Depth 40) -ErrorAction Stop
        Remove-VmSessionFromCache -VmName $Target.Name
    }
}

function Invoke-MQFix {
    param($Target, [string]$FixName, [scriptblock]$Body)
    Clear-MQFixStamp -Target $Target -FixName $FixName
    $fix = @(Get-MQFixes -Target $Target | Where-Object FixName -eq $FixName)
    if ($fix.Count -ne 1) { throw "Scoped VM $($Target.Name) has no unique applicable $FixName." }
    if ($Body) { $fix[0].ScriptBlock = $Body }
    $result = Start-VMFix -VMName $Target.Name -VMFix $fix[0]
    if (-not $result.Success -or -not $result.Applied) { throw "$FixName recovery failed on $($Target.Name)." }
    $note = Assert-MQTarget -Target $Target
    if (-not (Test-VMFixApplied -VMNote $note -FixName $FixName -FixVersion $fix[0].FixVersion)) {
        throw "$FixName reported success without the required VM-note stamp."
    }
    return $fix[0]
}

function Get-MQInventory {
    param($Target, [switch]$InspectOnly)
    $note = Assert-MQTarget -Target $Target
    $fixes = @(Get-MQFixes -Target $Target)
    $odbc = $fixes | Where-Object FixName -eq 'Fix-ODBC18' | Select-Object -First 1
    $request = [pscustomobject]@{
        InspectOnly = $InspectOnly.IsPresent
        OdbcRequired = if ($odbc) { "$($odbc.ArgumentList[0])" } else { '' }
        ConsoleRequired = @($fixes | Where-Object FixName -eq 'Fix-Upgrade-Console').Count -gt 0
        AdminRequired = @($fixes | Where-Object FixName -eq 'Fix-CMFullAdmin').Count -gt 0
        Helpers = $script:MQConsoleHelpers
    }
    $probe = {
        param($Request)
        $ErrorActionPreference = 'Stop'
        $out = [ordered]@{
            ComputerName = $env:COMPUTERNAME; Identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            OdbcRequired = $Request.OdbcRequired; Drivers = @(); Products = @()
            Driver17 = @()
            ConsoleRequired = $Request.ConsoleRequired; Console = $null
            AdminRequired = $Request.AdminRequired; AdminPresent = $false
            History = @()
            GuestConfigSha256 = if (Test-Path -LiteralPath 'C:\staging\DSC\deployConfig.json') {
                (Get-FileHash -LiteralPath 'C:\staging\DSC\deployConfig.json' -Algorithm SHA256).Hash
            } else { '' }
        }
        foreach ($registry in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
            $driverKey = "$registry\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server"
            $versionKey = "$registry\Microsoft\MSODBCSQL18"
            $driver = if (Test-Path -LiteralPath $driverKey) { Get-ItemProperty -LiteralPath $driverKey } else { $null }
            $version = if (Test-Path -LiteralPath $versionKey) { Get-ItemProperty -LiteralPath $versionKey } else { $null }
            $path = "$($driver.Driver)"
            $exists = [bool]($path -and (Test-Path -LiteralPath $path -PathType Leaf))
            $out.Drivers += [pscustomobject]@{
                View = $registry; Version = "$($version.InstalledVersion)"; Path = $path
                Exists = $exists
                DllVersion = if ($exists) { (Get-Item -LiteralPath $path).VersionInfo.ProductVersion } else { '' }
            }
            $key17 = "$registry\ODBC\ODBCINST.INI\ODBC Driver 17 for SQL Server"
            $version17 = "$registry\Microsoft\MSODBCSQL17"
            $driver17 = if (Test-Path -LiteralPath $key17) { Get-ItemProperty -LiteralPath $key17 } else { $null }
            $installed17 = if (Test-Path -LiteralPath $version17) { Get-ItemProperty -LiteralPath $version17 } else { $null }
            $out.Driver17 += [pscustomobject]@{ View = $registry; Version = "$($installed17.InstalledVersion)"; Path = "$($driver17.Driver)" }
        }
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $related = $null
        try {
            $related = $installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @('{ADA68B65-BFF8-4E6A-B082-CC6682D425B8}'))
            foreach ($code in $related) {
                $state = [int]$installer.GetType().InvokeMember('ProductState', 'GetProperty', $null, $installer, @($code))
                [uint32]$packed = $installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'Version'))
                $cache = if ($state -eq 5) { [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'LocalPackage')) } else { '' }
                $out.Products += [pscustomobject]@{
                    ProductCode = "$code"; State = $state
                    Version = ([version]::new([int]($packed -shr 24), [int](($packed -shr 16) -band 255), [int]($packed -band 65535))).ToString()
                    PackageCode = [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'PackageCode'))
                    PackageName = [string]$installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'PackageName'))
                    Cache = $cache; CacheExists = [bool]($cache -and (Test-Path -LiteralPath $cache -PathType Leaf))
                }
            }
        }
        finally {
            foreach ($item in @($related, $installer)) {
                if ($item -and [Runtime.InteropServices.Marshal]::IsComObject($item)) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item) }
            }
        }
        foreach ($name in @('Fix-ODBC18', 'Fix-Upgrade-Console', 'Fix-CMFullAdmin')) {
            $path = "C:\staging\Fix\history\$name"
            $out.History += [pscustomobject]@{
                FixName = $name
                Count = if (Test-Path -LiteralPath $path) { @(Get-ChildItem -LiteralPath $path -File -Filter '*.result.json').Count } else { 0 }
            }
        }
        if (-not $Request.InspectOnly -and $Request.ConsoleRequired) {
            . ([scriptblock]::Create($Request.Helpers))
            $site = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification').'Site Code'
            $directory = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Setup').'Installation Directory'
            $payload = Get-ConsolePayloadState -SiteInstallDirectory $directory
            $state = Get-ConsoleVersionState -SiteCode $site -ExpectedRelease $payload.Release -ExpectedConsoleVersion $payload.ConsoleVersion `
                -LiveSiteBuild $payload.LiveSiteBuild -PayloadSiteBuild $payload.PayloadSiteBuild
            $out.Console = [pscustomobject]@{ Ready = [bool]($state.Current -or $state.NewerThanSite); State = $state; Payload = $payload }
        }
        if (-not $Request.InspectOnly -and $Request.AdminRequired) {
            $site = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification').'Site Code'
            $setup = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\Setup'
            Import-Module (Join-Path $setup.'UI Installation Directory' 'bin\ConfigurationManager.psd1') -ErrorAction Stop
            $provider = "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
            $created = $false
            if (-not (Get-PSDrive -Name $site -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                $null = New-PSDrive -Name $site -PSProvider CMSite -Root $provider -ErrorAction Stop
                $created = $true
            }
            Push-Location "${site}:\"
            try {
                $out.AdminPresent = @(Get-CMAdministrativeUser -RoleName 'Full Administrator' -ErrorAction Stop |
                    Where-Object LogonName -ieq "$env:USERDOMAIN\vmbuildadmin").Count -gt 0
            }
            finally { Pop-Location; if ($created) { Remove-PSDrive -Name $site -Force } }
        }
        return [pscustomobject]$out
    }
    $inventory = Invoke-MQGuest -Target $Target -ScriptBlock $probe -Arguments $request
    return [pscustomobject]@{
        Name = $Target.Name; Id = "$($Target.Id)"; Domain = $note.domain; Role = $note.role
        Fixes = @($fixes | Select-Object FixName, FixVersion)
        Inventory = $inventory
    }
}

function Assert-MQReadiness {
    param([object[]]$Inventories)
    foreach ($entry in $Inventories) {
        $info = $entry.Inventory
        if ($info.ComputerName -ine $entry.Name) { throw 'Independent readiness inspected the wrong guest.' }
        if ($info.OdbcRequired) {
            [version]$required = $info.OdbcRequired
            if (@($info.Drivers).Count -ne 2 -or @($info.Drivers | Where-Object {
                        -not $_.Exists -or -not $_.Version -or [version]$_.Version -lt $required -or
                        -not $_.DllVersion -or [version]$_.DllVersion -lt $required
                    }).Count) { throw "Independent x64/x86 ODBC readiness failed on $($entry.Name)." }
            $minimum = [version]::new($required.Major, $required.Minor, $required.Build)
            if (-not @($info.Products | Where-Object { $_.State -eq 5 -and $_.CacheExists -and [version]$_.Version -ge $minimum }).Count) {
                throw "Windows Installer cache/product readiness failed on $($entry.Name)."
            }
        }
        if ($info.ConsoleRequired -and -not $info.Console.Ready) { throw "Live console policy readiness failed on $($entry.Name)." }
        if ($info.AdminRequired -and -not $info.AdminPresent) { throw "The exact Full Administrator principal is missing on $($entry.Name)." }
        $target = $script:MQTargets | Where-Object Name -eq $entry.Name | Select-Object -First 1
        $note = Assert-MQTarget -Target $target
        foreach ($fix in $entry.Fixes) {
            if ($Mode -eq 'Postconditions' -and $fix.FixName -eq 'Fix-CMFullAdmin') { continue }
            if (-not (Test-VMFixApplied -VMNote $note -FixName $fix.FixName -FixVersion $fix.FixVersion)) {
                throw "Readiness passed but $($fix.FixName) was not stamped on $($entry.Name)."
            }
        }
    }
}

function Add-MQCase {
    param([string]$Name, [object]$Data, [string]$Status = 'Passed', [string]$Reason)
    $script:MQReceipt.Cases = @($script:MQReceipt.Cases | Where-Object Name -ne $Name) +
        [pscustomobject]@{ Name = $Name; Status = $Status; Reason = $Reason; Data = $Data; CompletedUtc = [datetime]::UtcNow.ToString('o') }
    Write-MaintenanceQualificationReceipt -Path $ReceiptPath -Receipt $script:MQReceipt
}

function Start-MQCase {
    param([string]$Name)
    $script:MQReceipt.ActiveCase = $Name
    Write-MaintenanceQualificationReceipt -Path $ReceiptPath -Receipt $script:MQReceipt
}

function Invoke-MQPreflight {
    . (Join-Path $root 'common\Common.Prereqs.ps1')
    $state = Get-MemLabsDscArtifactState -DscRoot (Join-Path $root 'DSC')
    if (-not $state.Current) { throw "Candidate DSC artifact is stale: $($state.Reason)" }
    Add-MQCase 'dsc-artifact' $state
    $powershell = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) { throw 'Windows PowerShell 5.1 is required for the candidate preflight.' }
    foreach ($name in @(Get-MaintenanceQualificationCases Preflight | Where-Object { $_ -ne 'dsc-artifact' })) {
        $scriptName = if ($name -in @('Test-WindowsClientSetupReadiness-PS7', 'Test-WindowsClientSetupReadiness-PS51')) {
            'Test-WindowsClientSetupReadiness'
        } else { $name }
        $engine = if ($name -in @('Test-MainToDevelopExpansionRunner', 'Test-WindowsClientSetupReadiness-PS7')) {
            (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
        } else { $powershell }
        Write-Host "Running pinned candidate regression: $name ($engine)"
        & $engine -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "$scriptName.ps1") | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Pinned candidate regression failed: $name (exit $LASTEXITCODE)." }
        Add-MQCase $name ([pscustomobject]@{ ExitCode = 0; Engine = $engine; Script = "$scriptName.ps1" })
    }
}

function Invoke-MQBaseline {
    $before = @($script:MQTargets | ForEach-Object { Get-MQInventory -Target $_ -InspectOnly })
    foreach ($target in $script:MQTargets) {
        $null = Assert-MQTarget $target
        if (-not (Start-VMMaintenance -VMName $target.Name)) { throw "Existing-site maintenance failed on $($target.Name)." }
    }
    Add-MQCase 'existing-maintenance' ([pscustomobject]@{ Before = $before })
    $ready = @($script:MQTargets | ForEach-Object { Get-MQInventory -Target $_ })
    Assert-MQReadiness $ready
    foreach ($entry in $before) {
        $after = $ready | Where-Object Name -eq $entry.Name | Select-Object -First 1
        if ($entry.Inventory.GuestConfigSha256 -cne $after.Inventory.GuestConfigSha256) {
            throw "Existing-site maintenance replaced legacy deployment configuration on $($entry.Name)."
        }
    }
    Add-MQCase 'independent-readiness' $ready
    foreach ($target in $script:MQTargets) {
        if (-not (Start-VMMaintenance -VMName $target.Name)) { throw "Maintenance idempotence failed on $($target.Name)." }
    }
    $again = @($script:MQTargets | ForEach-Object { Get-MQInventory -Target $_ })
    Assert-MQReadiness $again
    foreach ($entry in $ready) {
        $second = $again | Where-Object Name -eq $entry.Name | Select-Object -First 1
        if (($entry.Inventory.History | ConvertTo-Json -Compress) -cne ($second.Inventory.History | ConvertTo-Json -Compress)) {
            throw "Maintenance reran already-completed fix bodies on $($entry.Name)."
        }
    }
    Add-MQCase 'maintenance-idempotence' ([pscustomobject]@{ After = $again; NoAdditionalAttempts = $true })
    foreach ($target in $script:MQTargets) { $null = Assert-MQTarget $target }
    Add-MQCase 'identity-preserved' @($script:MQTargets)
}

function Get-MQFixtureScript {
    return {
        param($Request)
        $ErrorActionPreference = 'Stop'
        if ($Request.Root -notmatch '^C:\\staging\\Fix\\qualification\\[0-9a-f]{32}$') { throw 'Invalid qualification fixture directory.' }
        $null = New-Item -Path $Request.Root -ItemType Directory -Force
        function Read-Package {
            param([string]$Path)
            $installer = New-Object -ComObject WindowsInstaller.Installer
            $database = $null; $summary = $null
            $values = @{}
            try {
                $database = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
                foreach ($name in @('ProductCode', 'ProductVersion', 'UpgradeCode')) {
                    $view = $null; $record = $null
                    try {
                        $query = "SELECT ``Value`` FROM ``Property`` WHERE ``Property``='$name'"
                        $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @($query))
                        $null = $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                        if (-not $record) { throw "Qualification MSI lacks $name." }
                        $values[$name] = [string]$record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
                    }
                    finally {
                        foreach ($item in @($record, $view)) { if ($item) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item) } }
                    }
                }
                $summary = $database.GetType().InvokeMember('SummaryInformation', 'GetProperty', $null, $database, @(0))
                $values.PackageCode = [string]$summary.GetType().InvokeMember('Property', 'GetProperty', $null, $summary, @(9))
            }
            finally {
                foreach ($item in @($summary, $database, $installer)) { if ($item) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item) } }
            }
            return [pscustomobject]$values
        }
        function Download-Package {
            param([string]$Url, [string]$Path, [string]$Version)
            $null = New-Item -Path (Split-Path $Path -Parent) -ItemType Directory -Force
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $client = New-Object Net.WebClient
            try { $client.DownloadFile($Url, $Path) } finally { $client.Dispose() }
            $signature = Get-AuthenticodeSignature -LiteralPath $Path
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)') {
                throw 'Qualification fixture MSI has no valid Microsoft signature.'
            }
            $info = Read-Package $Path
            if ($info.ProductVersion -ne $Version -or $info.UpgradeCode -ine '{ADA68B65-BFF8-4E6A-B082-CC6682D425B8}') {
                throw 'Qualification fixture is not the exact requested x64 ODBC 18 package.'
            }
            return $info
        }
        function Invoke-FixtureMsi {
            param([string]$Arguments, [string]$Name)
            $line = "$Arguments /qn /norestart IACCEPTMSODBCSQLLICENSETERMS=YES SKIPPENDINGREBOOTCHECK=1 /l*v `"$($Request.Root)\$Name.log`""
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                $process = Start-Process msiexec.exe -ArgumentList $line -Wait -PassThru -NoNewWindow
                if ($process.ExitCode -ne 1618 -or $attempt -eq 3) { break }
                Start-Sleep -Seconds 30
            }
            if ($process.ExitCode -notin @(0, 3010)) { throw "Qualification fixture MSI exited $($process.ExitCode): $Name" }
        }
        function Get-ProductInfo {
            param([string]$Code, [string]$Property)
            $installer = New-Object -ComObject WindowsInstaller.Installer
            try { return $installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($Code, $Property)) }
            catch { throw "Windows Installer lookup '$Code'/'$Property' failed: $($_.Exception.Message)" }
            finally { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($installer) }
        }
        function Make-Advertised {
            param([string]$Code)
            $plain = $Code.Trim('{}') -replace '-', ''
            $packed = (-join $plain.Substring(0,8).ToCharArray()[7..0]) +
                (-join $plain.Substring(8,4).ToCharArray()[3..0]) +
                (-join $plain.Substring(12,4).ToCharArray()[3..0]) +
                [regex]::Replace($plain.Substring(16), '(..)', { param($m) "$($m.Value[1])$($m.Value[0])" })
            $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$packed\InstallProperties"
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
        }
        function Lose-SourceAndCache {
            param([string]$Source, [string]$Code, [switch]$DriverRegistration)
            $cache = [string](Get-ProductInfo $Code 'LocalPackage')
            if (-not $cache -or -not (Test-Path -LiteralPath $cache) -or (Read-Package $cache).ProductCode -ine $Code) {
                throw 'Qualification cannot identify the exact cached MSI to remove.'
            }
            Remove-Item -LiteralPath $Source -Force
            Remove-Item -LiteralPath $cache -Force
            Make-Advertised $Code
            if ($DriverRegistration) {
                foreach ($registry in @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node')) {
                    $path = "$registry\ODBC\ODBCINST.INI\ODBC Driver 18 for SQL Server"
                    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force }
                }
            }
            return [pscustomobject]@{ OriginalMissing = -not (Test-Path -LiteralPath $Source); CacheMissing = -not (Test-Path -LiteralPath $cache); ProductCode = $Code }
        }
        switch ($Request.Operation) {
            'SeedLegacy' {
                $path = Join-Path $Request.Root 'legacy\qualification-legacy.msi'
                $info = Download-Package 'https://go.microsoft.com/fwlink/?linkid=2214634&clcid=0x409' $path '18.1.2.1'
                $installer = New-Object -ComObject WindowsInstaller.Installer
                $related = $null
                $codes = @()
                try {
                    $related = $installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @($info.UpgradeCode))
                    foreach ($code in $related) {
                        [uint32]$packed = $installer.GetType().InvokeMember('ProductInfo', 'GetProperty', $null, $installer, @($code, 'Version'))
                        $version = [version]::new([int]($packed -shr 24), [int](($packed -shr 16) -band 255), [int]($packed -band 65535))
                        $maximum = [version]$Request.Version
                        if ($version -gt [version]::new($maximum.Major, $maximum.Minor, $maximum.Build)) {
                            throw 'Qualification will not replace a driver newer than the candidate target.'
                        }
                        $codes += "$code"
                    }
                }
                finally {
                    foreach ($item in @($related, $installer)) { if ($item) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item) } }
                }
                foreach ($code in $codes) {
                    if ($code -ine $info.ProductCode) { Invoke-FixtureMsi "/x $code" 'seed-remove-current' }
                }
                Invoke-FixtureMsi "/i `"$path`" ADDLOCAL=ALL REINSTALLMODE=vomus" 'seed-legacy'
                return Lose-SourceAndCache $path $info.ProductCode
            }
            'LoseCurrent' {
                $installer = New-Object -ComObject WindowsInstaller.Installer
                $related = $null
                try {
                    $related = $installer.GetType().InvokeMember('RelatedProducts', 'GetProperty', $null, $installer, @('{ADA68B65-BFF8-4E6A-B082-CC6682D425B8}'))
                    $codes = @(foreach ($code in $related) {
                            $state = [int]$installer.GetType().InvokeMember('ProductState', 'GetProperty', $null, $installer, @($code))
                            if ($state -ne 5) { continue }
                            if ([string](Get-ProductInfo $code 'VersionString') -eq $Request.Version) { "$code" }
                        })
                }
                finally {
                    foreach ($item in @($related, $installer)) { if ($item) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($item) } }
                }
                if ($codes.Count -ne 1) { throw 'Qualification requires one exact current-version ODBC product.' }
                $name = [string](Get-ProductInfo $codes[0] 'PackageName')
                if ([IO.Path]::GetFileName($name) -cne $name) { throw 'Unsafe registered qualification package name.' }
                $path = Join-Path $Request.Root "current\$name"
                $info = Download-Package $Request.Url $path $Request.Version
                if ($info.ProductCode -ine $codes[0]) { throw 'Current fixture identity differs from the installed product.' }
                Invoke-FixtureMsi "/i `"$path`" ADDLOCAL=ALL REINSTALL=ALL REINSTALLMODE=vomus" 'seed-current'
                return Lose-SourceAndCache $path $info.ProductCode -DriverRegistration
            }
            'LegacyConfig' {
                $path = 'C:\staging\DSC\deployConfig.json'
                $backup = Join-Path $Request.Root 'deployConfig.restore.json'
                if (Test-Path -LiteralPath $path) {
                    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $path -Destination $backup -Force }
                    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                    foreach ($options in @($config.cmOptions) + @($config.virtualMachines | ForEach-Object { $_.cmOptions })) {
                        if ($options -and $options.PSObject.Properties['Version']) { $options.PSObject.Properties.Remove($options.PSObject.Properties['Version'].Name) }
                    }
                    $config | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $path -Encoding UTF8
                }
                return [pscustomobject]@{ VersionRemoved = $true }
            }
            'NewerConsole' {
                $key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\Setup'
                $backup = Join-Path $Request.Root 'console-version.restore.json'
                if (-not (Test-Path -LiteralPath $backup)) {
                    [pscustomobject]@{ Version = (Get-ItemProperty -LiteralPath $key).AdminConsoleVersion } |
                        ConvertTo-Json | Set-Content -LiteralPath $backup -Encoding UTF8
                }
                Set-ItemProperty -LiteralPath $key -Name AdminConsoleVersion -Value '5.9999.9999.9999'
                return [pscustomobject]@{ Version = '5.9999.9999.9999' }
            }
            'Restore' {
                $backup = Join-Path $Request.Root 'deployConfig.restore.json'
                if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination 'C:\staging\DSC\deployConfig.json' -Force }
                elseif (Test-Path -LiteralPath (Join-Path $Request.Root 'config-created.flag')) {
                    if (Test-Path -LiteralPath 'C:\staging\DSC\deployConfig.json') { Remove-Item -LiteralPath 'C:\staging\DSC\deployConfig.json' -Force }
                }
                $backup = Join-Path $Request.Root 'console-version.restore.json'
                if (Test-Path -LiteralPath $backup) {
                    $value = Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json
                    Set-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\Setup' -Name AdminConsoleVersion -Value $value.Version
                }
                return [pscustomobject]@{ Restored = $true }
            }
            'RemoveAdmin' {
                $target = "$env:USERDOMAIN\vmbuildadmin"
                if ([Security.Principal.WindowsIdentity]::GetCurrent().Name -ieq $target) { throw 'Qualification will not remove its own setup administrator.' }
                $site = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\SMS\Identification').'Site Code'
                $setup = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\ConfigMgr10\Setup'
                Import-Module (Join-Path $setup.'UI Installation Directory' 'bin\ConfigurationManager.psd1') -ErrorAction Stop
                $created = $false
                if (-not (Get-PSDrive -Name $site -PSProvider CMSite -ErrorAction SilentlyContinue)) {
                    $null = New-PSDrive -Name $site -PSProvider CMSite -Root "$env:COMPUTERNAME.$env:USERDNSDOMAIN"
                    $created = $true
                }
                Push-Location "${site}:\"
                try {
                    foreach ($user in @(Get-CMAdministrativeUser -ErrorAction Stop | Where-Object LogonName -ieq $target)) {
                        Remove-CMAdministrativeUser -InputObject $user -Force -ErrorAction Stop
                    }
                    if (@(Get-CMAdministrativeUser -ErrorAction Stop | Where-Object LogonName -ieq $target).Count) { throw 'Administrator fixture was not removed.' }
                }
                finally { Pop-Location; if ($created) { Remove-PSDrive -Name $site -Force } }
                return [pscustomobject]@{ Removed = $target }
            }
            'History' {
                $path = "C:\staging\Fix\history\$($Request.FixName)"
                return @(Get-ChildItem -LiteralPath $path -File -Filter '*.result.json' |
                    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 12 |
                    ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
            }
            'Latest' {
                return Get-Content -LiteralPath "C:\staging\Fix\$($Request.FixName).result.json" -Raw | ConvertFrom-Json
            }
            'Catalogue' {
                $path = 'C:\staging\DSC\deployConfig.json'
                $backup = Join-Path $Request.Root 'deployConfig.restore.json'
                if (Test-Path -LiteralPath $path) {
                    if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $path -Destination $backup }
                    $config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
                }
                else {
                    $true | Set-Content -LiteralPath (Join-Path $Request.Root 'config-created.flag')
                    $config = [pscustomobject]@{}
                }
                $link = [regex]::Match($Request.Url, '(?i)[?&]linkid=(\d+)')
                if (-not $link.Success) { throw 'Candidate ODBC recovery catalogue has no pinned Microsoft release link.' }
                if (-not $config.PSObject.Properties['URLMetadata']) { $config | Add-Member -NotePropertyName URLMetadata -NotePropertyValue ([pscustomobject]@{}) }
                $config.URLMetadata | Add-Member -NotePropertyName ODBC -NotePropertyValue ([pscustomobject]@{
                        version = $Request.Version; fwlink = [int]$link.Groups[1].Value
                    }) -Force
                $config | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $path -Encoding UTF8
                return [pscustomobject]@{ CatalogueFixture = $true }
            }
            default { throw "Unknown maintenance qualification fixture operation $($Request.Operation)" }
        }
    }
}

function Invoke-MQFixture {
    param($Target, [string]$Operation, [string]$FixName, [string]$Version, [string]$Url)
    $request = [pscustomobject]@{ Root = $script:MQGuestRoot; Operation = $Operation; FixName = $FixName; Version = $Version; Url = $Url }
    return Invoke-MQGuest -Target $Target -ScriptBlock (Get-MQFixtureScript) -Arguments $request -TimeoutSeconds 600
}

function Invoke-MQRecovery {
    if (-not $script:MQReceipt.HasCmTarget) {
        foreach ($name in @(Get-MaintenanceQualificationCases Recovery)) { Add-MQCase $name $null 'NotApplicable' 'No CAS or standalone Primary exists in the scoped family.' }
        return
    }
    $target = @($script:MQTargets | Where-Object {
            $note = Assert-MQTarget $_
            $note.role -eq 'CAS' -or ($note.role -eq 'Primary' -and -not $note.parentSiteCode)
        } | Sort-Object Name)[0]
    $null = Invoke-MQFixture $target Restore
    foreach ($name in @('Fix-ODBC18', 'Fix-Upgrade-Console', 'Fix-CMFullAdmin')) { Clear-MQFixStamp $target $name }
    if (-not (Start-VMMaintenance -VMName $target.Name)) { throw 'Recovery target could not be restored to a healthy candidate baseline.' }
    $odbc = @(Get-MQFixes $target | Where-Object FixName -eq 'Fix-ODBC18')[0]
    $version = "$($odbc.ArgumentList[0])"
    $url = "$($odbc.ArgumentList[1])"
    $driver17Before = (Get-MQInventory $target -InspectOnly).Inventory.Driver17 | ConvertTo-Json -Compress
    $recoveryFailure = $null
    try {
        Start-MQCase 'legacy-msi-source-cache-loss'
        $injected = Invoke-MQFixture $target SeedLegacy -Version $version
        if (-not $injected.OriginalMissing -or -not $injected.CacheMissing) { throw 'Legacy source/cache fixture was not established.' }
        $null = Invoke-MQFix $target 'Fix-ODBC18'
        $ready = @(Get-MQInventory $target)
        Assert-MQReadiness $ready
        Add-MQCase 'legacy-msi-source-cache-loss' ([pscustomobject]@{ Injected = $injected; After = $ready })

        Start-MQCase 'current-msi-registration-cache-loss'
        $injected = Invoke-MQFixture $target LoseCurrent -Version $version -Url $url
        if (-not $injected.OriginalMissing -or -not $injected.CacheMissing) { throw 'Current source/cache fixture was not established.' }
        $null = Invoke-MQFix $target 'Fix-ODBC18'
        $ready = @(Get-MQInventory $target)
        Assert-MQReadiness $ready
        Add-MQCase 'current-msi-registration-cache-loss' ([pscustomobject]@{ Injected = $injected; After = $ready })

        Start-MQCase 'legacy-console-config'
        $null = Invoke-MQFixture $target LegacyConfig
        $null = Invoke-MQFix $target 'Fix-Upgrade-Console'
        $marker = Invoke-MQFixture $target Latest -FixName 'Fix-Upgrade-Console'
        if (-not $marker.State.ExpectedConsoleVersion) { throw 'Console recovery did not record a live target.' }
        Add-MQCase 'legacy-console-config' $marker
        $null = Invoke-MQFixture $target Restore

        Start-MQCase 'newer-console-preserved'
        $null = Invoke-MQFixture $target NewerConsole
        $console = @(Get-MQFixes $target | Where-Object FixName -eq 'Fix-Upgrade-Console')[0]
        $body = [scriptblock]::Create("function Start-Process { throw 'QUALIFICATION_UNSAFE_CONSOLE_SETUP' }`n& {`n$($console.ScriptBlock.ToString())`n} @args")
        $null = Invoke-MQFix $target 'Fix-Upgrade-Console' -Body $body
        $marker = Invoke-MQFixture $target Latest -FixName 'Fix-Upgrade-Console'
        if (-not $marker.PreservedNewer) { throw 'Newer console preservation was not exercised.' }
        Add-MQCase 'newer-console-preserved' $marker
        $null = Invoke-MQFixture $target Restore

        Start-MQCase 'administrator-assignment'
        $null = Invoke-MQFixture $target RemoveAdmin
        $null = Invoke-MQFix $target 'Fix-CMFullAdmin'
        $ready = @(Get-MQInventory $target)
        Assert-MQReadiness $ready
        Add-MQCase 'administrator-assignment' $ready

        Start-MQCase 'retry-and-evidence'
        $odbc = @(Get-MQFixes $target | Where-Object FixName -eq 'Fix-ODBC18')[0]
        $flag = "$script:MQGuestRoot\retry-count.txt"
        $body = [scriptblock]::Create(@"
`$flag = '$flag'
`$count = if (Test-Path -LiteralPath `$flag) { [int](Get-Content -LiteralPath `$flag) + 1 } else { 1 }
`$count | Set-Content -LiteralPath `$flag
if (`$count -eq 1) { return [pscustomobject]@{ Success = `$false; Message = 'QUALIFICATION_TRANSIENT_$script:MQRunId' } }
& {
$($odbc.ScriptBlock.ToString())
} @args
"@)
        $null = Invoke-MQGuest $target { param($Path) if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force } } @($flag)
        $began = [datetime]::UtcNow
        $null = Invoke-MQFix $target 'Fix-ODBC18' -Body $body
        $history = @(Invoke-MQFixture $target History -FixName 'Fix-ODBC18' | Where-Object { ([datetimeoffset]$_.StartedAt).UtcDateTime -ge $began })
        if ($history.Count -ne 2 -or @($history | Where-Object { -not $_.Success }).Count -ne 1) {
            throw 'Real transport retry did not retain exactly one failed and one successful attempt.'
        }
        $ordered = @($history | Sort-Object StartedAt)
        if ((([datetimeoffset]$ordered[1].StartedAt).UtcDateTime - ([datetimeoffset]$ordered[0].StartedAt).UtcDateTime).TotalSeconds -lt 60) { throw 'Maintenance retried before the required 60-second backoff.' }
        $logs = @(Get-ChildItem -LiteralPath (Split-Path $Common.LogPath -Parent) -File -Filter "$($target.Name)-Fix-ODBC18-*.diagnostics.log" |
            Where-Object { $_.LastWriteTimeUtc -ge $began -and $_.LastWriteTimeUtc -le ([datetimeoffset]$ordered[1].StartedAt).UtcDateTime })
        if (-not $logs.Count) { throw 'No host evidence was saved before the successful retry.' }
        Add-MQCase 'retry-and-evidence' ([pscustomobject]@{ Attempts = $ordered; Evidence = @($logs.FullName) })

        Start-MQCase 'unverifiable-package-rejected'
        Invoke-MQPackageRejection -Target $target
        Start-MQCase 'packaged-dsc-recovery'
        Invoke-MQPackagedRecovery -Target $target -Version $version -Url $url
        $driver17After = (Get-MQInventory $target -InspectOnly).Inventory.Driver17 | ConvertTo-Json -Compress
        if ($driver17Before -cne $driver17After) { throw 'ODBC recovery changed the side-by-side Driver 17 installation.' }
    }
    catch { $recoveryFailure = $_; throw }
    finally {
        try { $null = Invoke-MQFixture $target Restore }
        catch {
            if (-not $recoveryFailure) { throw }
            $script:MQReceipt.RestorationError = "$($_.Exception.Message)"
            Write-Warning "Fixture restoration also failed; original qualification failure is retained: $($_.Exception.Message)"
        }
    }
    $script:MQReceipt.ActiveCase = $null
}

function Invoke-MQPackageRejection {
    param($Target)
    $notesBefore = Assert-MQTarget $Target | ConvertTo-Json -Depth 40 -Compress
    $before = Get-MQInventory $Target -InspectOnly
    $product = @($before.Inventory.Products | Where-Object State -eq 5 | Sort-Object Version -Descending)[0]
    if (-not $product) { throw 'No installed ODBC product is available for the rejection assertion.' }
    $fix = @(Get-MQFixes $Target | Where-Object FixName -eq 'Fix-ODBC18')[0]
    $definitions = ''
    foreach ($name in @('Get-MsiVersion', 'Save-OdbcInstaller', 'Save-OdbcRecoveryInstaller')) {
        $definition = $fix.ScriptBlock.Ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
        if (-not $definition) { throw "Candidate recovery helper $name is missing." }
        $definitions += $definition.Extent.Text + "`n"
    }
    $request = [pscustomobject]@{
        Definitions = $definitions; ProductCode = $product.ProductCode; Version = $product.Version
        PackageName = $product.PackageName
    }
    $outcome = Invoke-MQGuest $Target {
        param($Request)
        . ([scriptblock]::Create($Request.Definitions))
        $product = [pscustomobject]@{
            ProductCode = $Request.ProductCode; Version = [version]$Request.Version
            PackageCode = [guid]::NewGuid().ToString('B')
            UpgradeCode = '{ADA68B65-BFF8-4E6A-B082-CC6682D425B8}'
            PackageName = $Request.PackageName; Language = 1033
        }
        $failure = $null
        try { $null = Save-OdbcRecoveryInstaller -Product $product }
        catch { $failure = $_.Exception.Message }
        if (-not $failure -or $failure -notmatch 'identity mismatch') {
            throw "Candidate did not reject a signed MSI with the wrong package identity: $failure"
        }
        [pscustomobject]@{ Rejected = $true; Reason = $failure }
    } @($request)
    $after = Get-MQInventory $Target -InspectOnly
    if (($before.Inventory.Drivers | ConvertTo-Json -Compress) -cne ($after.Inventory.Drivers | ConvertTo-Json -Compress) -or
        ($before.Inventory.Driver17 | ConvertTo-Json -Compress) -cne ($after.Inventory.Driver17 | ConvertTo-Json -Compress) -or
        ($before.Inventory.Products | Sort-Object ProductCode | ConvertTo-Json -Compress) -cne ($after.Inventory.Products | Sort-Object ProductCode | ConvertTo-Json -Compress) -or
        $notesBefore -cne (Assert-MQTarget $Target | ConvertTo-Json -Depth 40 -Compress)) {
        throw 'Package rejection changed installed driver/MSI state or VM-note success stamps.'
    }
    Add-MQCase 'unverifiable-package-rejected' $outcome
}

function Invoke-MQPackagedRecovery {
    param($Target, [string]$Version, [string]$Url)
    $null = Invoke-MQFixture $Target Catalogue -Version $Version -Url $Url
    $injected = Invoke-MQFixture $Target LoseCurrent -Version $Version -Url $Url
    if (-not $injected.OriginalMissing -or -not $injected.CacheMissing) { throw 'Packaged DSC source/cache fixture was not established.' }
    $note = Assert-MQTarget $Target
    $account = if ($note.adminName) { $note.adminName } else { $note.domainAdmin }
    $session = Get-VmSession -VmName $Target.Name -VmDomainName $note.domain -VmDomainAccount $account -RequireDomainIdentity
    if (-not $session) { throw 'Cannot copy the pinned DSC archive to the scoped recovery guest.' }
    $destination = "$script:MQGuestRoot\DSC.zip"
    Copy-Item -LiteralPath (Join-Path $root 'DSC\DSC.zip') -Destination $destination -ToSession $session -Force -ErrorAction Stop
    $request = [pscustomobject]@{
        Root = $script:MQGuestRoot
        Hash = $script:MQSource.Files['DSC\TemplateHelpDSC\TemplateHelpDSC.psm1']
    }
    $outcome = Invoke-MQGuest $Target {
        param($Request)
        Expand-Archive -LiteralPath (Join-Path $Request.Root 'DSC.zip') -DestinationPath (Join-Path $Request.Root 'packaged') -Force
        $path = Join-Path $Request.Root 'packaged\TemplateHelpDSC\TemplateHelpDSC.psm1'
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($hash -cne $Request.Hash) { throw 'The shipped DSC module differs from the qualified candidate source.' }
        $module = Import-Module (Join-Path $Request.Root 'packaged\TemplateHelpDSC\TemplateHelpDSC.psd1') -Force -PassThru
        & $module {
            $resource = [InstallODBCDriver]::new()
            $resource.ODBCPath = 'C:\temp\msodbcsql.msi'
            $resource.Ensure = 'Present'
            $resource.Set()
            if (-not $resource.Test()) { throw 'The actual shipped DSC resource did not recover the fixture.' }
        }
        [pscustomobject]@{ ModuleSha256 = $hash; Recovered = $true }
    } @($request) -TimeoutSeconds 900
    $ready = @(Get-MQInventory $Target)
    Assert-MQReadiness $ready
    Add-MQCase 'packaged-dsc-recovery' ([pscustomobject]@{ Injected = $injected; Result = $outcome; After = $ready })
}

try {
    $script:MQSource = Get-MaintenanceQualificationSource -VmbuildRoot $root
    if ($script:MQSource.Commit -cne $DevelopRevision -or ($RequireCleanSource -and $script:MQSource.Dirty)) {
        throw 'Maintenance qualification must use the requested clean pinned develop candidate.'
    }
    if ($Mode -ne 'Preflight') {
        if (-not $TargetsPath -or -not $AdminCachePath) { throw 'Live qualification requires scoped targets and the existing credential cache.' }
        $parsedTargets = Get-Content -LiteralPath $TargetsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $script:MQTargets = @($parsedTargets)
        if (-not $script:MQTargets.Count) { throw 'Live maintenance qualification has no scoped VM identities.' }
        if (@($script:MQTargets.Name | Select-Object -Unique).Count -ne $script:MQTargets.Count -or
            @($script:MQTargets.Id | Select-Object -Unique).Count -ne $script:MQTargets.Count) {
            throw 'Duplicate VM identities in the qualification scope.'
        }
    }
    $script:MQReceipt = [ordered]@{
        SchemaVersion = 1; Mode = $Mode; MainRevision = $MainRevision; DevelopRevision = $DevelopRevision
        Family = $Family; Source = $script:MQSource; RunId = $script:MQRunId
        StartedUtc = [datetime]::UtcNow.ToString('o'); CompletedUtc = $null; Status = 'Running'
        Targets = @($script:MQTargets | Select-Object Name, Id); HasCmTarget = $false; Cases = @(); Error = $null
    }
    if (Test-Path -LiteralPath $ReceiptPath) {
        $prior = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $oldTargets = @($prior.Targets | ForEach-Object { "$($_.Name)|$($_.Id)".ToLowerInvariant() } | Sort-Object) -join "`n"
        $newTargets = @($script:MQTargets | ForEach-Object { "$($_.Name)|$($_.Id)".ToLowerInvariant() } | Sort-Object) -join "`n"
        if ($prior.Mode -cne $Mode -or $prior.MainRevision -cne $MainRevision -or $prior.DevelopRevision -cne $DevelopRevision -or
            $prior.Source.Digest -cne $script:MQSource.Digest -or $oldTargets -cne $newTargets) {
            throw 'Existing qualification receipt belongs to a different candidate or mode.'
        }
        $script:MQReceiptWritable = $true
        $script:MQRunId = "$($prior.RunId)"
        if ($script:MQRunId -notmatch '^[0-9a-f]{32}$') { throw 'Invalid qualification receipt run identity.' }
        $script:MQGuestRoot = "C:\staging\Fix\qualification\$script:MQRunId"
        $script:MQReceipt.RunId = $script:MQRunId
    }
    Write-MaintenanceQualificationReceipt -Path $ReceiptPath -Receipt $script:MQReceipt
    $script:MQReceiptWritable = $true
    if ($Mode -eq 'Preflight') { Invoke-MQPreflight }
    else {
        . (Join-Path $root 'Common.ps1') -FastInit
        if (-not (Test-Path -LiteralPath $AdminCachePath -PathType Leaf)) { throw 'The main baseline credential cache is unavailable.' }
        $credentialDirectory = Join-Path $root 'cache'
        $null = New-Item -Path $credentialDirectory -ItemType Directory -Force
        $candidateCredential = Join-Path $credentialDirectory 'vmbuildadmin.txt'
        if ([IO.Path]::GetFullPath($AdminCachePath) -ine [IO.Path]::GetFullPath($candidateCredential)) {
            Copy-Item -LiteralPath $AdminCachePath -Destination $candidateCredential -Force -ErrorAction Stop
        }
        if (-not (Get-LocalAdminCredential)) { throw 'Could not load the scoped baseline credential.' }
        $global:MemLabsRequireDomainIdentity = $true
        $Common.InJob = $true
        $consolePath = Join-Path $root 'DSC\phases\Upgrade-Console.ps1'
        $ast = [Management.Automation.Language.Parser]::ParseFile($consolePath, [ref]$null, [ref]$null)
        $script:MQConsoleHelpers = ''
        foreach ($name in @('Get-ConsolePayloadState', 'Get-ConsoleVersionState')) {
            $definition = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}, $true)
            if (-not $definition) { throw "Missing candidate console helper $name." }
            $script:MQConsoleHelpers += $definition.Extent.Text + "`n"
        }
        foreach ($target in $script:MQTargets) { $null = Assert-MQTarget $target }
        $script:MQReceipt.HasCmTarget = @($script:MQTargets | Where-Object {
                $note = Assert-MQTarget $_
                $note.role -eq 'CAS' -or ($note.role -eq 'Primary' -and -not $note.parentSiteCode)
            }).Count -gt 0
        switch ($Mode) {
            'Baseline' { Invoke-MQBaseline }
            'Postconditions' {
                $ready = @($script:MQTargets | ForEach-Object { Get-MQInventory -Target $_ })
                Assert-MQReadiness $ready
                Add-MQCase 'independent-readiness' $ready
                foreach ($target in $script:MQTargets) { $null = Assert-MQTarget $target }
                Add-MQCase 'identity-preserved' @($script:MQTargets)
            }
            'Recovery' { Invoke-MQRecovery }
        }
    }
    $after = Get-MaintenanceQualificationSource -VmbuildRoot $root
    if ($after.Digest -cne $script:MQSource.Digest -or $after.Commit -cne $DevelopRevision -or ($RequireCleanSource -and $after.Dirty)) {
        throw 'Candidate source changed while maintenance qualification was running.'
    }
    $script:MQReceipt.Status = 'Passed'
    $script:MQReceipt.CompletedUtc = [datetime]::UtcNow.ToString('o')
    Write-MaintenanceQualificationReceipt -Path $ReceiptPath -Receipt $script:MQReceipt
    Write-Host "PASS: $Mode maintenance qualification receipt: $ReceiptPath"
    exit 0
}
catch {
    if ($script:MQReceipt -and $script:MQReceiptWritable) {
        $script:MQReceipt.Status = 'Failed'
        $script:MQReceipt.Error = "$($_.Exception.Message)"
        Write-MaintenanceQualificationReceipt -Path $ReceiptPath -Receipt $script:MQReceipt
    }
    Write-Host "Maintenance qualification failed; retain scoped VMs and evidence: $($_.Exception.Message)"
    exit 1
}
