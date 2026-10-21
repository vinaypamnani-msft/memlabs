#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path $PSScriptRoot 'Test-WindowsFirstLogonImage.ps1'
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$null, [ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
$definitions = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
foreach ($definition in $definitions) {
    . ([scriptblock]::Create($definition.Extent.Text.Replace('$PSScriptRoot', "'$($PSScriptRoot.Replace("'", "''"))'")))
}
. Import-MemLabsImageComparisonHelpers
function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $message = $null
    try { $null = & $Action } catch { $message = $_.Exception.Message }
    Assert-True ($message -match $Pattern) "Expected '$Pattern', got '$message'."
}
$root = Join-Path ([IO.Path]::GetTempPath()) "memlabs-image-compare-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -Path $root -ItemType Directory
try {
    $tools = Join-Path $root 'tools'
    $cache = Join-Path $root 'azureFiles'
    $source = Join-Path $cache 'os\WIN11-TEST.vhdx'
    $null = New-Item -Path $tools, (Split-Path $source -Parent) -ItemType Directory -Force
    [IO.File]::WriteAllText($source, 'SYNTHETIC-INDEPENDENT-GENERALIZED-IMAGE')
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    $original = [pscustomobject]@{
        Id = [guid]::NewGuid(); Name = 'ORIGINAL-W11'; Path = (Join-Path $root 'lab\ORIGINAL-W11')
        Notes = '{"operatingSystem":"WIN11-TEST"}'; Generation = 2; State = 'Off'; ProcessorCount = 2
    }
    [IO.File]::WriteAllText((Join-Path $cache '_fileList_develop.json'), '{"OS":[{"id":"WIN11-TEST","filename":"os\\WIN11-TEST.vhdx"}]}')
    $candidateDefinition = @($definitions | Where-Object Name -eq 'Get-MemLabsComparisonImageCandidates')[0]
    . ([scriptblock]::Create($candidateDefinition.Extent.Text.Replace('$PSScriptRoot', "'$($tools.Replace("'", "''"))'")))
    $candidates = @(Get-MemLabsComparisonImageCandidates -OriginalVM $original)
    Assert-True ($candidates.Count -eq 1 -and $candidates[0].Matched -and $candidates[0].Path -eq $source) 'Guided source discovery did not match the VM OS ID to the local cached image.'
    Assert-True ((Select-MemLabsComparisonImage -OriginalVM $original) -eq $source) 'A unique exact image match did not select automatically.'
    [IO.File]::WriteAllText((Join-Path $cache '_fileList_develop.json'), '{"OS":[{"id":"WIN11-TEST","filename":"..\\outside.vhdx"}]}')
    Assert-Throws { Get-MemLabsComparisonImageCandidates -OriginalVM $original } 'escapes'
    [IO.File]::WriteAllText((Join-Path $cache '_fileList_develop.json'), '{"OS":[]}')
    $fallback = @(Get-MemLabsComparisonImageCandidates -OriginalVM $original)
    Assert-True ($fallback.Count -eq 1 -and -not $fallback[0].Matched) 'A filename-only candidate was falsely marked as a verified OS-ID match.'
    $script:Selections = 0
    function Read-Host { param($Prompt); $script:Selections++; return '1' }
    Assert-True ((Select-MemLabsComparisonImage -OriginalVM $original) -eq $source -and $script:Selections -eq 1) 'Fallback selection was not explicit and guided.'
    $null = Select-MemLabsComparisonImage -OriginalVM $original -PreviewOnly
    Assert-True ($script:Selections -eq 1) 'WhatIf prompted for a source choice.'

    $workspace = Join-Path $root 'inspection'
    $guest = Join-Path $root 'synthetic-volume'
    $windows = Join-Path $guest 'Windows'
    $sfap = Join-Path $guest 'Users\Default\AppData\Local\Microsoft\Windows\SFAP'
    $null = New-Item -Path $workspace, (Join-Path $workspace 'Control'), (Join-Path $workspace 'Test'),
        (Join-Path $windows 'System32\config'), (Join-Path $windows 'Panther'), $sfap -ItemType Directory -Force
    foreach ($name in @('SYSTEM','SOFTWARE')) { [IO.File]::WriteAllText((Join-Path $windows "System32\config\$name"), 'SYNTHETIC-HIVE-DO-NOT-EXPORT') }
    $answer = Join-Path $windows 'Panther\unattend.xml'
    $answerXml = '<unattend><settings><component><CopyProfile>true</CopyProfile></component></settings></unattend>'
    [IO.File]::WriteAllText($answer, $answerXml)
    [IO.File]::WriteAllText((Join-Path $sfap 'cache0.bin'), 'SYNTHETIC-CREDENTIAL-CACHE-DO-NOT-EXPORT')
    $cacheHash = (Get-FileHash -LiteralPath (Join-Path $sfap 'cache0.bin') -Algorithm SHA256).Hash
    $script:ExpectedMode = 'Source'; $script:Mounts = 0; $script:Dismounts = 0; $script:Pristine = $true; $script:DismountFails = $false
    function Get-VHD {
        param($Path,$ErrorAction)
        [pscustomobject]@{ Attached = $false; ParentPath = '' }
    }
    function Mount-VHD {
        param($Path,[switch]$ReadOnly,[switch]$NoDriveLetter,[switch]$Passthru,$ErrorAction)
        Assert-True ([bool]$ReadOnly -eq ($script:ExpectedMode -eq 'Source') -and $NoDriveLetter -and $Passthru) 'Image inspection changed the access mode or assigned a drive letter.'
        $script:Mounts++
        [pscustomobject]@{ DiskNumber = 42 }
    }
    function Get-Disk { param($Number,$ErrorAction); Assert-True ($Number -eq 42) 'Inspection accessed an unowned disk.'; [pscustomobject]@{ Number = 42; IsReadOnly = ($script:ExpectedMode -eq 'Source'); IsOffline = $false } }
    function Get-Partition {
        param($DiskNumber,$ErrorAction)
        Assert-True ($DiskNumber -eq 42) 'Inspection enumerated another disk.'
        [pscustomobject]@{ PartitionNumber = 1; GptType = '{E3C9E316-0B5C-4DB8-817D-F92DF00215AE}' }
        [pscustomobject]@{ PartitionNumber = 4; GptType = '{EBD0A0A2-B9E5-4433-87C0-68B6B72699C7}' }
    }
    function Get-Volume {
        param($Partition,$ErrorAction)
        Assert-True ($Partition.PartitionNumber -eq 4) 'Inspection tried to query a volume on a Microsoft Reserved partition.'
        [pscustomobject]@{ Path = $guest }
    }
    function Dismount-VHD {
        param($Path,$ErrorAction)
        $script:Dismounts++
        if ($script:DismountFails) { throw 'Synthetic dismount failure' }
    }
    function Read-MemLabsOfflineWindowsSetupHive {
        param($Path,$Kind)
        Assert-True ($Path -match '\\Private-[a-f0-9]{32}\\(SYSTEM|SOFTWARE)$') 'Inspection read a live/mounted hive instead of a private copy.'
        if ($Kind -eq 'SYSTEM') { return @{ Setup = @{ Values = @{ SetupType = 2 } } } }
        @{ WindowsVersion = @{ Values = @{ InstallationType = 'Client'; CurrentBuild = '26300' } }
            ImageState = @{ Values = @{ ImageState = $(if ($script:Pristine) { 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE' } else { 'IMAGE_STATE_COMPLETE' }) } } }
    }
    $before = Invoke-MemLabsComparisonImageInspection -Path $source -Mode Source -Workspace $workspace
    Assert-True ($before.Access -eq 'ReadOnly' -and $before.Caches.Count -eq 1 -and -not $before.Caches[0].Removed -and
        (Get-FileHash -LiteralPath (Join-Path $sfap 'cache0.bin') -Algorithm SHA256).Hash -eq $cacheHash) 'Source inspection changed its cache.'
    $script:ExpectedMode = 'Control'
    $controlDisk = Join-Path $workspace 'Control\Control.vhdx'
    $control = Invoke-MemLabsComparisonImageInspection -Path $controlDisk -Mode Control -Workspace $workspace
    Assert-True (-not $control.Caches[0].Removed -and (Test-Path -LiteralPath $sfap)) 'The control intervention removed cache state.'
    $mounts = $script:Mounts
    Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path $source -Mode Test -Workspace $workspace } 'exact disposable trial disk'
    Assert-True ($script:Mounts -eq $mounts) 'Writable inspection reached a source/original path.'
    $script:ExpectedMode = 'Source'; $script:Pristine = $false
    Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path $source -Mode Source -Workspace $workspace } 'not a generalized'
    Assert-True ((Test-Path -LiteralPath (Join-Path $sfap 'cache0.bin'))) 'A completed/failed OS disk was modified.'
    $script:Pristine = $true
    [IO.File]::WriteAllText($answer, '<unattend><CopyProfile>true</CopyProfile><JoinDomain>must-not-join.test</JoinDomain></unattend>')
    Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path $source -Mode Source -Workspace $workspace } 'requests a domain join'
    [IO.File]::WriteAllText($answer, $answerXml)
    [IO.File]::WriteAllText((Join-Path $sfap 'Unexpected.bin'), 'leave this alone')
    $script:ExpectedMode = 'Test'
    Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path (Join-Path $workspace 'Test\Test.vhdx') -Mode Test -Workspace $workspace } 'Unexpected SFAP contents'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $sfap 'cache0.bin') -Algorithm SHA256).Hash -eq $cacheHash) 'Unexpected contents caused partial cache mutation.'
    [IO.File]::Delete((Join-Path $sfap 'Unexpected.bin'))
    [IO.File]::WriteAllText((Join-Path $sfap 'cache0.bin'), ('X' * (1MB + 1)), [Text.UTF8Encoding]::new($false))
    Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path (Join-Path $workspace 'Test\Test.vhdx') -Mode Test -Workspace $workspace } 'expected bound'
    Assert-True ((Test-Path -LiteralPath (Join-Path $sfap 'cache0.bin'))) 'An oversized cache was partially removed.'
    [IO.File]::WriteAllText((Join-Path $sfap 'cache0.bin'), 'SYNTHETIC-CREDENTIAL-CACHE-DO-NOT-EXPORT')
    $linked = Join-Path $guest 'Users\LinkedProfile\AppData\Local\Microsoft\Windows\SFAP'
    $null = New-Item -Path (Split-Path $linked -Parent) -ItemType Directory -Force
    $null = New-Item -Path $linked -ItemType Junction -Target $sfap
    try {
        Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path (Join-Path $workspace 'Test\Test.vhdx') -Mode Test -Workspace $workspace } 'reparse'
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $sfap 'cache0.bin') -Algorithm SHA256).Hash -eq $cacheHash) 'A reparse path broadened mutation or allowed partial cache deletion.'
    }
    finally { [IO.Directory]::Delete($linked) }
    $cleaned = Invoke-MemLabsComparisonImageInspection -Path (Join-Path $workspace 'Test\Test.vhdx') -Mode Test -Workspace $workspace
    Assert-True ($cleaned.Caches[0].Removed -and -not (Test-Path -LiteralPath $sfap) -and $script:Mounts -eq $script:Dismounts) 'Only the disposable test cache was not removed, or an owned mount leaked.'
    Assert-True (@(Get-ChildItem -LiteralPath $workspace -Directory -Filter 'Private-*').Count -eq 0) 'Private raw-hive copies were retained.'
    $null = New-Item -Path $sfap -ItemType Directory -Force
    [IO.File]::WriteAllText((Join-Path $sfap 'cache0.bin'), 'SYNTHETIC-CREDENTIAL-CACHE-DO-NOT-EXPORT')
    $script:ExpectedMode = 'Source'; $script:DismountFails = $true
    Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path $source -Mode Source -Workspace $workspace } 'could not be detached'
    Assert-True (@(Get-ChildItem -LiteralPath $workspace -Directory -Filter 'Private-*').Count -eq 0 -and
        (Test-Path -LiteralPath (Join-Path $sfap 'cache0.bin'))) 'A dismount failure leaked private hive copies or changed source cache state.'
    $script:DismountFails = $false

    $encodedFixture = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('SYNTHETIC-NOT-A-REAL-PASSWORDPassword'))
    $autoAnswer = '<unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup"><CopyProfile>true</CopyProfile></component></settings><settings pass="oobeSystem"><component name="Microsoft-Windows-Shell-Setup"><OOBE><HideEULAPage>true</HideEULAPage></OOBE><UserAccounts><LocalAccounts><LocalAccount><Name>fixture-admin</Name><Group>Administrators</Group><Password><Value>' +
        $encodedFixture + '</Value><PlainText>false</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts></component></settings></unattend>'
    $stagingAnswer = Join-Path $guest 'staging\Unattend.xml'
    $null = New-Item -Path (Split-Path $stagingAnswer -Parent) -ItemType Directory -Force
    $scrubbedAnswer = $autoAnswer.Replace($encodedFixture, '*SENSITIVE*DATA*DELETED*')
    [IO.File]::WriteAllText($stagingAnswer, $autoAnswer)
    [IO.File]::WriteAllText($answer, $scrubbedAnswer)
    $answerHash = (Get-FileHash -LiteralPath $answer -Algorithm SHA256).Hash
    $masterHash = (Get-FileHash -LiteralPath $stagingAnswer -Algorithm SHA256).Hash
    $autoArguments = @{ Workspace = $workspace; TestVariant = 'ExplicitAutoLogon'; AutoLogonUserName = 'fixture-admin' }
    $script:ExpectedMode = 'Source'
    $autoSource = Invoke-MemLabsComparisonImageInspection -Path $source -Mode Source @autoArguments
    $script:ExpectedMode = 'Control'
    $autoControl = Invoke-MemLabsComparisonImageInspection -Path $controlDisk -Mode Control @autoArguments
    Assert-True (-not $autoSource.ExplicitAutoLogon.Configured -and -not $autoControl.ExplicitAutoLogon.Configured -and
        (Get-FileHash -LiteralPath $answer -Algorithm SHA256).Hash -eq $answerHash -and
        (Get-FileHash -LiteralPath $stagingAnswer -Algorithm SHA256).Hash -eq $masterHash) 'Explicit-sign-in preflight changed the source/control answer files.'
    $script:ExpectedMode = 'Test'
    $autoTest = Invoke-MemLabsComparisonImageInspection -Path (Join-Path $workspace 'Test\Test.vhdx') -Mode Test @autoArguments
    Assert-True ($autoTest.ExplicitAutoLogon.Configured -and $autoTest.ExplicitAutoLogon.AnswerFiles.Count -eq 2 -and
        @($autoTest.Caches | Where-Object Removed).Count -eq 0 -and
        (Get-FileHash -LiteralPath (Join-Path $sfap 'cache0.bin') -Algorithm SHA256).Hash -eq $cacheHash -and
        ($autoTest | ConvertTo-Json -Depth 10) -notmatch [regex]::Escape($encodedFixture)) `
        'Explicit-sign-in mode deleted caches, lost its matched answer changes, or exported the password element.'
    foreach ($path in @($answer,$stagingAnswer)) {
        $document = [xml]::new(); $document.XmlResolver = $null
        $document.LoadXml((Get-Content -LiteralPath $path -Raw))
        $auto = $document.SelectSingleNode('//*[local-name()="AutoLogon"]')
        Assert-True ($auto.NamespaceURI -eq 'urn:schemas-microsoft-com:unattend' -and
            $auto.SelectSingleNode('*[local-name()="Username"]').InnerText -eq 'fixture-admin' -and
            $auto.SelectSingleNode('*[local-name()="Domain"]').InnerText -eq '.' -and
            $auto.SelectSingleNode('*[local-name()="LogonCount"]').InnerText -eq '1' -and
            $auto.SelectSingleNode('*[local-name()="Password"]/*[local-name()="Value"]').InnerText -ceq $encodedFixture -and
            $auto.SelectSingleNode('*[local-name()="Password"]/*[local-name()="PlainText"]').InnerText -eq 'false' -and
            $document.SelectSingleNode('//*[local-name()="HideEULAPage"]').InnerText -eq 'true') `
            'Trial autologon lost schema namespace, existing password encoding, preserved OOBE settings, or the exact local account/count.'
    }
    Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path (Join-Path $workspace 'Test\Test.vhdx') -Mode Test @autoArguments } 'already configures'
    foreach ($variant in @('WrongUser','MissingPassword','NonAdmin','DuplicateAccount','NamespaceMismatch')) {
        [IO.File]::WriteAllText($stagingAnswer, $autoAnswer)
        [IO.File]::WriteAllText($answer, $scrubbedAnswer)
        $arguments = @{} + $autoArguments
        switch ($variant) {
            WrongUser { $arguments.AutoLogonUserName = 'different-admin' }
            MissingPassword { [IO.File]::WriteAllText($stagingAnswer, $scrubbedAnswer) }
            NonAdmin { [IO.File]::WriteAllText($stagingAnswer, $autoAnswer.Replace('<Group>Administrators</Group>','<Group>Users</Group>')) }
            DuplicateAccount {
                $xml = [xml]::new(); $xml.XmlResolver = $null; $xml.LoadXml($autoAnswer)
                $accounts = $xml.SelectSingleNode('//*[local-name()="LocalAccounts"]')
                $null = $accounts.AppendChild($accounts.FirstChild.CloneNode($true))
                [IO.File]::WriteAllText($stagingAnswer,$xml.OuterXml)
            }
            NamespaceMismatch { [IO.File]::WriteAllText($answer,$scrubbedAnswer.Replace(' xmlns="urn:schemas-microsoft-com:unattend"','')) }
        }
        $beforePanther = (Get-FileHash -LiteralPath $answer -Algorithm SHA256).Hash
        $beforeMaster = (Get-FileHash -LiteralPath $stagingAnswer -Algorithm SHA256).Hash
        Assert-Throws { Invoke-MemLabsComparisonImageInspection -Path (Join-Path $workspace 'Test\Test.vhdx') -Mode Test @arguments } `
            'does not uniquely match|No usable|not explicitly|different XML namespaces'
        Assert-True ((Get-FileHash -LiteralPath $answer -Algorithm SHA256).Hash -eq $beforePanther -and
            (Get-FileHash -LiteralPath $stagingAnswer -Algorithm SHA256).Hash -eq $beforeMaster -and
            (Test-Path -LiteralPath (Join-Path $sfap 'cache0.bin'))) 'A rejected explicit-sign-in plan partially changed files or caches.'
    }
    [IO.File]::WriteAllText($answer,$answerXml)
    [IO.File]::Delete($stagingAnswer)

    $copy = Join-Path $root 'verified-copy.vhdx'
    Copy-MemLabsComparisonDisk -Source $source -Destination $copy -ExpectedHash $sourceHash
    Assert-True ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -eq $sourceHash -and
        (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -eq $sourceHash) 'The real bounded copy worker modified the source or lost copy integrity.'

    & {
        $spec = [pscustomobject]@{ Label = 'Control'; Name = 'ML-OOBE-C-native'; Root = (Join-Path $root 'native-trial'); Disk = (Join-Path $root 'native-trial\Control.vhdx') }
        $null = New-Item -Path $spec.Root -ItemType Directory
        [IO.File]::Copy($source,$spec.Disk)
        $token = 'native-owner-token'
        $hardware = [pscustomobject]@{ Startup = 1GB; Minimum = 1GB; Maximum = 4GB; Dynamic = $true; Processors = 2; Switch = 'LAB-SWITCH'; SecureBoot = 'On'; Template = 'MicrosoftWindows'; Tpm = $true }
        $script:NativeVm = $null; $script:NativeRemoved = $false; $script:NativeDiskDrift = $false; $script:NativeCheckpoint = $false
        $script:NativeConfiguration = [Collections.Generic.List[string]]::new()
        function Invoke-MemLabsComparisonWorker { param($Block,$Arguments,$TimeoutSeconds,$Operation); Assert-True ($TimeoutSeconds -eq 120) 'Creation lost its bound.'; & $Block @Arguments }
        function Import-Module { param($Name,$ErrorAction); Assert-True ($Name -eq 'Hyper-V') 'Worker imported another host module.' }
        function Get-VM {
            param($Id,$ErrorAction)
            if ($Id) { return $script:NativeVm }
            if (-not $script:NativeRemoved -and $script:NativeVm) { return $script:NativeVm }
        }
        function New-VM {
            param($Name,$Path,$Generation,$VHDPath,$MemoryStartupBytes,$SwitchName,$ErrorAction)
            Assert-True ($Name -eq $spec.Name -and $Path -eq $spec.Root -and $Generation -eq 2 -and $VHDPath -eq $spec.Disk -and
                $SwitchName -eq 'LAB-SWITCH' -and $MemoryStartupBytes -eq 1GB) 'Native VM creation lost isolation/hardware/source matching.'
            $script:NativeVm = [pscustomobject]@{ Id = [guid]::NewGuid(); Name = $Name; Path = (Join-Path $Path $Name); State = 'Off'; Notes = '' }
            $script:NativeVm
        }
        function Set-VM {
            param($VM,$AutomaticCheckpointsEnabled,$AutomaticStartAction,$AutomaticStopAction,$Notes,$ErrorAction)
            Assert-True (-not $AutomaticCheckpointsEnabled -and $AutomaticStartAction -eq 'Nothing' -and $AutomaticStopAction -eq 'ShutDown') 'Trial VM can auto-start or checkpoint unexpectedly.'
            $VM.Notes = $Notes; $script:NativeConfiguration.Add('VM')
        }
        function Set-VMProcessor { param($VM,$Count,$ErrorAction); Assert-True ($Count -eq 2) 'Processor count drifted.'; $script:NativeConfiguration.Add('CPU') }
        function Set-VMMemory { param($VM,$DynamicMemoryEnabled,$MinimumBytes,$MaximumBytes,$StartupBytes,$ErrorAction); Assert-True ($DynamicMemoryEnabled -and $MinimumBytes -eq 1GB -and $MaximumBytes -eq 4GB -and $StartupBytes -eq 1GB) 'Memory settings drifted.'; $script:NativeConfiguration.Add('Memory') }
        function Set-VMFirmware { param($VM,$EnableSecureBoot,$SecureBootTemplate,$ErrorAction); Assert-True ($EnableSecureBoot -eq 'On' -and $SecureBootTemplate -eq 'MicrosoftWindows') 'Secure boot drifted.'; $script:NativeConfiguration.Add('Firmware') }
        function Set-VMKeyProtector { param($VM,[switch]$NewLocalKeyProtector,$ErrorAction); Assert-True $NewLocalKeyProtector 'Trial reused another VM''s TPM identity.'; $script:NativeConfiguration.Add('Key') }
        function Enable-VMTPM { param($VM,$ErrorAction); $script:NativeConfiguration.Add('TPM') }
        $created = New-MemLabsComparisonVm -Spec $spec -Hardware $hardware -Token $token
        Assert-True (($script:NativeConfiguration -join ',') -eq 'VM,CPU,Memory,Firmware,Key,TPM' -and
            $created.Id -ne $original.Id) 'The actual creation worker skipped matched configuration or selected the original.'
        function Get-VMHardDiskDrive { param($VM,$ErrorAction); [pscustomobject]@{ Path = $(if ($script:NativeDiskDrift) { $source } else { $spec.Disk }) } }
        function Get-VMSnapshot { param($VM,$ErrorAction); if ($script:NativeCheckpoint) { [pscustomobject]@{ Name = 'Unexpected' } } }
        function Remove-VM { param($VM,[switch]$Force,[switch]$AsJob,$ErrorAction); Assert-True ($VM.Id -eq $created.Id -and $Force -and $AsJob) 'Cleanup targeted an unowned VM or lost its bound.'; $script:NativeRemoved = $true; [pscustomobject]@{ State = 'Completed' } }
        function Wait-MemLabsOobeRepairJob { param($Job,$TimeoutSeconds,$Operation); Assert-True ($TimeoutSeconds -eq 60) 'Removal lost its deadline.' }
        foreach ($variant in @('Running','WrongToken','DiskDrift','Checkpoint')) {
            switch ($variant) {
                Running { $created.State = 'Running' }
                WrongToken { $created.Notes = '{"Purpose":"MemLabsFirstLogonComparison","Token":"other"}' }
                DiskDrift { $script:NativeDiskDrift = $true }
                Checkpoint { $script:NativeCheckpoint = $true }
            }
            Assert-Throws { Remove-MemLabsComparisonVm -VM $created -Spec $spec -Token $token } 'ownership/state/disk/checkpoint'
            Assert-True (-not $script:NativeRemoved -and [IO.File]::Exists($spec.Disk) -and [IO.File]::Exists($source)) 'A failed cleanup guard removed a VM or disk.'
            $created.State = 'Off'; $created.Notes = @{ Purpose = 'MemLabsFirstLogonComparison'; Token = $token } | ConvertTo-Json -Compress
            $script:NativeDiskDrift = $false; $script:NativeCheckpoint = $false
        }
        Remove-MemLabsComparisonVm -VM $created -Spec $spec -Token $token
        Assert-True ($script:NativeRemoved -and -not [IO.File]::Exists($spec.Disk) -and [IO.File]::Exists($source)) 'Verified owned cleanup removed the wrong disk or left its trial disk.'
    }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    function New-TrialArchive {
        param([string]$Path,[guid]$VMId,[string]$Observation,[bool]$Interactive = $true)
        $ready = $Observation -eq 'Ready'
        $reason = if ($ready) { 'MachineCompleteAwaitingFirstLogon' } elseif ($Observation -eq 'FirstLogonStall') { 'WindowsWelcomeIncomplete' } else { 'MachineSetupIncomplete' }
        $setup = [pscustomobject]@{
            Version = 1; Required = $true; ProductType = 1; Ready = $ready; Reason = $reason
            ImageState = $(if ($Observation -eq 'Other') { 'IMAGE_STATE_UNDEPLOYABLE' } else { 'IMAGE_STATE_COMPLETE' })
            SetupType = 0; SystemSetupInProgress = 0; OOBEInProgress = 0; NativeOobeComplete = $false
            WinRtOobeState = 'NotStarted'; SetupExeCompletion = 3
            OobeBlockingProcessCount = $(if ($ready) { 0 } else { 1 })
            OobeProcesses = @($(if (-not $ready) { 'FirstLogonAnim.exe' })); Diagnostics = @()
        }
        if ($ready) { $setup.OobeProcesses = @() }
        $actor = [pscustomobject]@{ Name = 'TEST\fixture-admin'; Sid = 'S-1-5-21-111-222-333-1000' }
        $processes = if ($ready -and $Interactive) { @([pscustomobject]@{ Name = 'explorer.exe'; SessionId = 1; OwnerSid = $actor.Sid }) } else { @() }
        $state = [pscustomobject]@{ Scope = 'WindowsFirstLogonProbe'; MachineGuid = [guid]::NewGuid().ToString('D'); Setup = $setup; Actor = $actor; Processes = $processes }
        $zip = [IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entries = @{
                'Manifest.json' = @{ VMId = $VMId.ToString('D'); FinalState = 'Off'; Status = 'Complete'; LiveProbe = @{ Status = 'Complete' } }
                'Live-StateBefore.json' = $state; 'Live-StateAfter.json' = $state
                'WindowsSetupState.json' = @{ SOFTWARE = @{ WinlogonProgress = @{ Values = @{ DefaultUserName = $(if ($ready) { 'fixture-admin' } else { 'defaultuser0' }) } } } }
            }
            foreach ($name in $entries.Keys) {
                $entry = $zip.CreateEntry($name)
                $writer = [IO.StreamWriter]::new($entry.Open())
                try { $writer.Write(($entries[$name] | ConvertTo-Json -Depth 10)) } finally { $writer.Dispose() }
            }
        }
        finally { $zip.Dispose() }
    }
    foreach ($observation in @('Ready','FirstLogonStall','Other')) {
        $id = [guid]::NewGuid()
        $path = Join-Path $root "$observation.zip"
        New-TrialArchive -Path $path -VMId $id -Observation $observation
        $evidence = Read-MemLabsComparisonDiagnostics -Archive $path -ExpectedVmId $id
        $expected = if ($observation -eq 'Other') { 'OtherOrTransitioning' } else { $observation }
        Assert-True ($evidence.Observation -eq $expected) 'A measured trial state was falsely classified.'
        Assert-Throws { Read-MemLabsComparisonDiagnostics -Archive $path -ExpectedVmId ([guid]::NewGuid()) } 'another VM'
    }

    $script:CredentialReads = 0; $script:Inspections = [Collections.Generic.List[string]]::new()
    $script:Started = [Collections.Generic.List[guid]]::new(); $script:Removed = [Collections.Generic.List[guid]]::new()
    $script:VMs = @{}; $script:Observations = @{ Control = 'FirstLogonStall'; Test = 'Ready' }; $script:StartupFails = $false; $script:NoInteractive = $false
    $secret = [Security.SecureString]::new(); $secret.AppendChar('x')
    $script:Credential = [pscredential]::new('fixture-admin',$secret)
    function Get-VM { param($Name,$Id,$ErrorAction); if ($Name -eq $original.Name) { return $original }; if ($Id) { return $script:VMs["$Id"] }; throw 'Unexpected original/unknown VM lookup.' }
    function Initialize-MemLabsSetupDiagnosticModules { param([switch]$IncludeLiveProbe); Assert-True $IncludeLiveProbe 'Comparison did not preflight live diagnostic dependencies.' }
    function Get-Command { param($Name,$ErrorAction); Assert-True ($Name -like 'Hyper-V\*') 'Unexpected command preflight.'; [pscustomobject]@{ Name = $Name } }
    function Resolve-MemLabsOobeRepairCredential { param([pscredential]$GuestCredential); $script:CredentialReads++; return $script:Credential }
    function Get-VMNetworkAdapter { param($VM,$ErrorAction); Assert-True ($VM.Id -eq $original.Id) 'Hardware reference changed.'; [pscustomobject]@{ SwitchName = 'LAB-SWITCH' } }
    function Get-VMNetworkAdapterVlan { param($VMNetworkAdapter,$ErrorAction); [pscustomobject]@{ OperationMode = 'Untagged' } }
    function Get-VMMemory { param($VM,$ErrorAction); [pscustomobject]@{ Startup = 1GB; Minimum = 1GB; Maximum = 4GB; DynamicMemoryEnabled = $true } }
    function Get-VMFirmware { param($VM,$ErrorAction); [pscustomobject]@{ SecureBoot = 'On'; SecureBootTemplate = 'MicrosoftWindows' } }
    function Get-VMSecurity { param($VM,$ErrorAction); [pscustomobject]@{ TpmEnabled = $true } }
    function Invoke-MemLabsComparisonImageInspection {
        param($Path,$Mode,$Workspace,$TestVariant,$AutoLogonUserName)
        $script:Inspections.Add($Mode)
        [pscustomobject]@{ ImageState = 'IMAGE_STATE_GENERALIZE_RESEAL_TO_OOBE'; CopyProfile = $true; Caches = @([pscustomobject]@{ Removed = ($Mode -eq 'Test' -and $TestVariant -eq 'SfapCache') }) }
    }
    function Invoke-MemLabsComparisonWorker {
        param($Block,$Arguments,$TimeoutSeconds,$Operation)
        & $Block @Arguments
    }
    function New-MemLabsComparisonVm {
        param($Spec,$Hardware,$Token)
        Assert-True (([IO.FileInfo]::new($Spec.Disk).Length -gt 0) -and $Hardware.Switch -eq 'LAB-SWITCH') 'VM creation lost its independent disk/matched network.'
        $vm = [pscustomobject]@{ Id = [guid]::NewGuid(); Name = $Spec.Name; State = 'Off'; Path = (Join-Path $Spec.Root $Spec.Name) }
        $script:VMs["$($vm.Id)"] = $vm
        return $vm
    }
    function Start-MemLabsOobeRepairVm {
        param($VM)
        Assert-True ($VM.Id -ne $original.Id -and @($script:VMs.Values | Where-Object State -eq 'Running').Count -eq 0) 'The original was started or trials were concurrent.'
        $script:Started.Add($VM.Id)
        if ($script:StartupFails) { throw 'Synthetic startup outcome unknown.' }
        $VM.State = 'Running'
    }
    function Invoke-MemLabsComparisonDiagnostics {
        param($VM,[pscredential]$GuestCredential,$Destination)
        Assert-True ([object]::ReferenceEquals($GuestCredential,$script:Credential) -and $VM.Id -ne $original.Id) 'Diagnostics targeted the original or wrong credential.'
        $null = New-Item -Path $Destination -ItemType Directory -Force
        $label = if ($VM.Name -like 'ML-OOBE-C-*') { 'Control' } else { 'Test' }
        $archive = Join-Path $Destination 'collected.zip'
        New-TrialArchive -Path $archive -VMId $VM.Id -Observation $script:Observations[$label] -Interactive:(-not $script:NoInteractive)
        $VM.State = 'Off'
        [pscustomobject]@{ FinalState = 'Off'; ArchivePath = $archive }
    }
    function Remove-MemLabsComparisonVm {
        param($VM,$Spec,$Token)
        Assert-True ($VM.Id -ne $original.Id -and $VM.State -eq 'Off') 'Cleanup touched the original or an unverified running VM.'
        $script:Removed.Add($VM.Id); [IO.File]::Delete($Spec.Disk)
    }
    $runs = Join-Path $root 'runs'
    $null = Invoke-MemLabsFirstLogonImageComparison -VmName $original.Name -SourceVhdxPath $source -Destination $runs -WhatIf
    Assert-True ($script:CredentialReads -eq 0 -and $script:Inspections.Count -eq 0 -and $script:Started.Count -eq 0 -and -not [IO.Directory]::Exists($runs)) 'WhatIf loaded credentials or mutated resources.'
    foreach ($scenario in @(
            @{ Control = 'FirstLogonStall'; Test = 'Ready'; Expected = 'supports the cache hypothesis' },
            @{ Control = 'Ready'; Test = 'Ready'; Expected = 'BothReady' },
            @{ Control = 'FirstLogonStall'; Test = 'FirstLogonStall'; Expected = 'BothBlocked' },
            @{ Control = 'Ready'; Test = 'FirstLogonStall'; Expected = 'do not adopt' },
            @{ Control = 'Other'; Test = 'Ready'; Expected = 'Inconclusive' },
            @{ Control = 'FirstLogonStall'; Test = 'Ready'; Variant = 'ExplicitAutoLogon'; Expected = 'ExplicitSignInCopyReadyControlBlocked' },
            @{ Control = 'FirstLogonStall'; Test = 'Ready'; Variant = 'ExplicitAutoLogon'; NoInteractive = $true; Expected = 'InconclusiveReadinessDifference' },
            @{ Control = 'FirstLogonStall'; Test = 'FirstLogonStall'; Variant = 'ExplicitAutoLogon'; Expected = 'explicit sign-in did not resolve' }
        )) {
        $script:Observations = $scenario
        $script:NoInteractive = [bool]$scenario.NoInteractive
        $startedBefore = $script:Started.Count; $removedBefore = $script:Removed.Count
        $variant = if ($scenario.Variant) { $scenario.Variant } else { 'SfapCache' }
        $result = Invoke-MemLabsFirstLogonImageComparison -VmName $original.Name -SourceVhdxPath $source -Destination $runs -TestVariant $variant
        Assert-True ($result.Status -eq 'Completed' -and $result.Verdict -match $scenario.Expected -and
            $script:Started.Count -eq $startedBefore + 2 -and $script:Removed.Count -eq $removedBefore + 2 -and
            $original.State -eq 'Off' -and (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -eq $sourceHash) `
            'Sequential comparison lost honest verdicts, isolated cleanup, or original/source preservation.'
        $zip = [IO.Compression.ZipFile]::OpenRead($result.ArchivePath)
        try {
            Assert-True ($zip.Entries.Count -eq 3 -and @($zip.Entries | Where-Object FullName -match '\.vhdx$').Count -eq 0) 'The upload archive contains trial disks or omits comparison/evidence files.'
        }
        finally { $zip.Dispose() }
    }
    $script:StartupFails = $true
    $before = $script:Started.Count
    Assert-Throws { Invoke-MemLabsFirstLogonImageComparison -VmName $original.Name -SourceVhdxPath $source -Destination $runs } 'startup outcome unknown'
    Assert-True ($script:Started.Count -eq $before + 1 -and $original.State -eq 'Off') 'Unknown startup proceeded to another arm or touched the original.'
    Assert-True (@($script:Started | Where-Object { $_ -eq $original.Id }).Count -eq 0 -and
        @($script:Removed | Where-Object { $_ -eq $original.Id }).Count -eq 0) 'The original VM was included in trial lifecycle actions.'

    $coldTools = Join-Path $root 'cold tools with spaces'
    $null = New-Item -Path $coldTools -ItemType Directory
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Get-WindowsVmSetupDiagnostics.ps1'), (Join-Path $PSScriptRoot 'Common.WindowsVmOobeRepair.ps1') `
        -Destination $coldTools -ErrorAction Stop
    $stub = @'
function Invoke-MemLabsFirstLogonImageComparison {
    [CmdletBinding(SupportsShouldProcess)]
    param($VmName,$SourceVhdxPath,$Destination,[pscredential]$GuestCredential,[switch]$KeepTrialVMs,[string]$TestVariant='SfapCache')
    if (-not $WhatIfPreference) {
        $inner = [Threading.Mutex]::new($false,'__LOCAL_MUTEX__')
        $acquired = $false
        try {
            $acquired = $inner.WaitOne(0)
            if (-not $acquired) { throw 'The nested collector could not reacquire the outer comparison lease.' }
        }
        finally { try { if ($acquired) { $inner.ReleaseMutex() } } finally { $inner.Dispose() } }
    }
    [pscustomobject]@{ VmName = $VmName; Source = $SourceVhdxPath; Destination = $Destination; Keep = [bool]$KeepTrialVMs; Variant = $TestVariant } | ConvertTo-Json -Compress
}
'@
    $lastDefinition = $definitions | Sort-Object { $_.Extent.EndOffset } | Select-Object -Last 1
    $fixtureSource = $ast.Extent.Text.Insert($lastDefinition.Extent.EndOffset, "`r`n$stub`r`n")
    $fixtureSource = [regex]::Replace($fixtureSource, '(?im)^#requires -RunAsAdministrator[ \t]*\r?\n', '')
    $localMutex = "Local\MemLabsImageComparisonFixture-$([guid]::NewGuid().ToString('N'))"
    $fixtureSource = $fixtureSource.Replace('Global\MemLabsTestMutationLock',$localMutex).Replace('__LOCAL_MUTEX__',$localMutex)
    $fixture = Join-Path $coldTools 'image comparison fixture.ps1'
    [IO.File]::WriteAllText($fixture,$fixtureSource,[Text.UTF8Encoding]::new($true))
    foreach ($engine in @((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), (Microsoft.PowerShell.Core\Get-Command pwsh.exe -CommandType Application).Source)) {
        foreach ($explicit in @($false,$true)) {
            foreach ($preview in @($false,$true)) {
                $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$fixture,'-VmName','ORIGINAL-W11')
                if ($preview) { $arguments += '-WhatIf' }
                if ($explicit) { $arguments += @('-SourceVhdxPath',$source,'-Destination',(Join-Path $root 'explicit output'),'-KeepTrialVMs','-TestVariant','ExplicitAutoLogon') }
                $output = @(& $engine @arguments 2>&1)
                if ($LASTEXITCODE -ne 0 -or $output.Count -ne 1) { throw "Cold comparison startup/lease failed: $($output -join ' ')" }
                $reply = $output[0] | ConvertFrom-Json -ErrorAction Stop
                Assert-True ($reply.VmName -eq 'ORIGINAL-W11' -and $reply.Keep -eq $explicit -and
                    $reply.Variant -eq $(if ($explicit) { 'ExplicitAutoLogon' } else { 'SfapCache' }) -and
                    (($explicit -and $reply.Source -eq $source) -or (-not $explicit -and -not $reply.Source))) `
                    'Dot-sourced helper imports lost real -File parameters, WhatIf routing, or recursive lease ownership.'
            }
        }
    }
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop }
Write-Host 'PASS -- guided source discovery, pristine-source and cache-only guards, private hive cleanup, real bounded copy, evidence/VM identity, sequential matched trials, honest verdicts, WhatIf and original preservation.'
