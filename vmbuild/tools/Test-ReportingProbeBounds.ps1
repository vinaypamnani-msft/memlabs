<#
.SYNOPSIS
    Exercises real bounded reporting web probes and the shared transport timeout.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Consumed by the imported transport function.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
if ($PSVersionTable.PSEdition -eq 'Core') {
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File $PSCommandPath -RootPath $RootPath
    if ($LASTEXITCODE -ne 0) { throw 'Reporting guest-runtime regression failed in Windows PowerShell 5.1.' }
    return
}
function Import-TestFunction {
    param([string] $Path, [string] $Name)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "$Path does not parse: $($errors -join '; ')" }
    $definitions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
            }, $true))
    if ($definitions.Count -ne 1) { throw "Expected one $Name definition." }
    [scriptblock]::Create($definitions[0].Extent.Text)
}
$collectorPath = Join-Path $RootPath 'tools\Get-ReportingDiagnostics.ps1'
foreach ($name in @('Get-ReportingCatalogEvidence', 'Get-ReportingPortalEvidence', 'Get-ReportingEndpointEvidence')) {
    . (Import-TestFunction -Path $collectorPath -Name $name)
}
. (Join-Path $RootPath 'DSC\phases\ProcessFunctions.ps1')

if (-not ('MemLabs.ReportingHttpFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Collections.Concurrent;
namespace MemLabs {
    public sealed class ReportingHttpFixture : IDisposable {
        private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        private readonly ManualResetEvent stopping = new ManualResetEvent(false);
        private readonly CountdownEvent workers = new CountdownEvent(1);
        private readonly Thread acceptThread;
        public readonly ConcurrentQueue<string> Requests = new ConcurrentQueue<string>();
        public readonly ConcurrentQueue<string> Errors = new ConcurrentQueue<string>();
        public volatile bool StallApi = true;
        public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }
        public ReportingHttpFixture() {
            listener.Start();
            acceptThread = new Thread(Accept);
            acceptThread.IsBackground = true;
            acceptThread.Start();
        }
        private void Accept() {
            while (!stopping.WaitOne(0)) {
                try {
                    TcpClient client = listener.AcceptTcpClient();
                    workers.AddCount();
                    ThreadPool.QueueUserWorkItem(delegate {
                        try { Serve(client); }
                        finally { workers.Signal(); }
                    });
                }
                catch (Exception ex) {
                    if (!stopping.WaitOne(0)) Errors.Enqueue(ex.ToString());
                    break;
                }
            }
        }
        private void Serve(TcpClient client) {
            using (client) {
                try {
                    NetworkStream stream = client.GetStream();
                    stream.ReadTimeout = 5000;
                    StreamReader reader = new StreamReader(stream, Encoding.ASCII);
                    string first = reader.ReadLine();
                    if (first == null) return;
                    string path = first.Split(' ')[1];
                    Requests.Enqueue(path);
                    string line;
                    do { line = reader.ReadLine(); } while (!String.IsNullOrEmpty(line));
                    bool api = path.StartsWith("/Reports/api/", StringComparison.OrdinalIgnoreCase);
                    string body = api ? "{\"value\":[]}" :
                        path.EndsWith("main.js", StringComparison.OrdinalIgnoreCase) ? "console.log('reporting');" :
                        "<html><title>Report Server</title><body>Reporting<script src='/Reports/main.js'></script></body></html>";
                    string contentType = api ? "application/json" :
                        path.EndsWith("main.js", StringComparison.OrdinalIgnoreCase) ? "application/javascript" : "text/html";
                    byte[] content = Encoding.UTF8.GetBytes(body);
                    bool stall = api && StallApi;
                    byte[] header = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: " + contentType +
                        "\r\nContent-Length: " + (stall ? 520 : content.Length) + "\r\nConnection: close\r\n\r\n");
                    stream.Write(header, 0, header.Length);
                    stream.Write(content, 0, content.Length);
                    stream.Flush();
                    if (stall) stopping.WaitOne(30000);
                }
                catch (IOException) { }
                catch (SocketException) { }
                catch (Exception ex) { Errors.Enqueue(ex.ToString()); }
            }
        }
        public void Dispose() {
            stopping.Set();
            listener.Stop();
            if (!acceptThread.Join(2000)) throw new TimeoutException("HTTP fixture did not stop.");
            workers.Signal();
            if (!workers.Wait(2000)) throw new TimeoutException("HTTP fixture requests did not stop.");
            workers.Dispose();
            stopping.Dispose();
        }
    }
}
'@
}
$server = [MemLabs.ReportingHttpFixture]::new()
try {
    $uri = [uri] "http://127.0.0.1:$($server.Port)/ReportServer"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $blocked = Get-ReportingEndpointEvidence -ServerUri $uri -SiteCode PS1 -TimeoutSeconds 3
    $clock.Stop()
    $portalProbe = $blocked.Probes | Where-Object { $_.Name -eq 'Portal' }
    if (-not $portalProbe.TimedOut -or $blocked.PortalError -notmatch '3-second wall-clock limit' -or
        $portalProbe.LastRequest -notmatch '/Reports/api/v2.0/CatalogItems' -or
        $blocked.ReportServerPage.StatusCode -ne 200 -or $clock.Elapsed.TotalSeconds -ge 18) {
        throw "Stalled HTTP body was not bounded with other evidence retained: $($blocked | ConvertTo-Json -Depth 6 -Compress)"
    }
    if (-not ($server.Requests.ToArray() | Where-Object { $_ -like '/Reports/api/*' })) { throw 'Fixture did not reach the stalled REST response.' }
    foreach ($probe in $blocked.Probes) {
        if ($probe.ProcessId -and (Get-Process -Id $probe.ProcessId -ErrorAction Ignore)) { throw "Reporting worker $($probe.ProcessId) was not stopped." }
    }
    $server.StallApi = $false
    $healthy = Get-ReportingEndpointEvidence -ServerUri $uri -SiteCode PS1 -TimeoutSeconds 8
    if ($healthy.PortalError -or $healthy.Portal.StatusCode -ne 200 -or
        $healthy.Portal.ScriptAssets.Count -ne 1 -or $healthy.Portal.RestApi.StatusCode -ne 200 -or
        -not $healthy.CatalogError) {
        throw "Real HTTP success/error evidence is incorrect: $($healthy | ConvertTo-Json -Depth 6 -Compress)"
    }
}
finally { $server.Dispose() }
if ($server.Errors.Count) { throw "HTTP fixture errors: $($server.Errors.ToArray() -join '; ')" }

. (Import-TestFunction -Path (Join-Path $RootPath 'Common.ps1') -Name 'Invoke-VmCommand')
$password = [System.Security.SecureString]::new()
$password.AppendChar([char]120)
$Common = [pscustomobject]@{ LocalAdmin = [pscredential]::new('fixture-admin', $password) }
$transport = [pscustomobject]@{
    Logs = [System.Collections.Generic.List[string]]::new()
    StopRequested = $false
    Evicted = $false
}
$session = [pscustomobject]@{
    State = 'Opened'; Availability = 'Busy'
    Runspace = [pscustomobject]@{
        RunspaceStateInfo = [pscustomobject]@{ State = 'Opened' }
        RunspaceAvailability = 'Busy'
    }
}
$child = [pscustomobject]@{
    State = 'Running'; JobStateInfo = [pscustomobject]@{ Reason = $null }
    Error = @(); Warning = @(); Verbose = @(); Information = @(); Output = @()
    Progress = @([System.Management.Automation.ProgressRecord]::new(1, 'Reading web response', 'Reading web response completed. (Number of bytes read: 520)'))
    HasMoreData = $true
}
$job = [pscustomobject]@{
    State = 'Running'; StatusMessage = ''; Location = 'RP-TEST'; ChildJobs = @($child)
    HasMoreData = $true; PSBeginTime = (Get-Date); PSEndTime = $null
    JobStateInfo = [pscustomobject]@{ Reason = $null }
}
$stopJob = { $transport.StopRequested = $true }.GetNewClosure()
$job | Add-Member ScriptMethod StopJobAsync $stopJob
function Write-Log {
    param($Text, [switch]$LogOnly, [switch]$Failure, [switch]$Warning, [switch]$Verbose)
    $transport.Logs.Add("$Text")
}
function Get-VMNote { param($VMName); [pscustomobject]@{ domain = 'example' } }
function Get-VmSession {
    param($VmName, $VmDomainName, $VmDomainAccount, $ShowVMSessionError, $MaxRetries, $LocalOnly, $RequireDomainIdentity, $Diagnostics, $Quiet)
    $session
}
function Enter-VmSessionInflight { param($Session, $DisplayName); 'fixture-token' }
function Exit-VmSessionInflight { param($Token) }
function Invoke-Command {
    param($Session, $ScriptBlock, $ArgumentList, $ErrorVariable, $ErrorAction, [switch]$AsJob)
    $job
}
function Wait-Job { param([Parameter(ValueFromPipeline)]$Job, $Timeout) process { } }
function Write-VmJobLedger { param($Op, $Job, $VmName, $DisplayName, $Detail) }
function Remove-VmSessionFromCache {
    param($VmName, [switch]$LeakSession, $AbandonedJob)
    $transport.Evicted = $LeakSession -and $null -ne $AbandonedJob
}
$threw = $false
try { $null = & $collectorPath -VMName RP-TEST -SiteCode PS1 -AsJson }
catch { $threw = $_.Exception.Message -match '600-second transport limit' }
if (-not $threw -or -not $transport.StopRequested -or -not $transport.Evicted -or
    -not ($transport.Logs | Where-Object { $_ -match 'Timeout autopsy.*Reading web response' })) {
    throw "Actual Invoke-VmCommand timeout was not surfaced or safely cancelled: $($transport | ConvertTo-Json -Compress)"
}
Write-Host 'PASS -- real reporting HTTP stalls are bounded, partial evidence survives, workers stop, and shared transport timeouts remain explicit.'
