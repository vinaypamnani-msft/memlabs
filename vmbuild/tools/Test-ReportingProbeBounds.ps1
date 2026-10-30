<#
.SYNOPSIS
    Exercises real bounded reporting web probes and the shared transport timeout.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', 'Common', Justification = 'Consumed by the imported transport function.')]
[CmdletBinding()]
param([string] $RootPath)

$ErrorActionPreference = 'Stop'
if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
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
foreach ($name in @('Invoke-ReportingWebRequest', 'Get-ReportingCatalogEvidence', 'Get-ReportingPortalEvidence', 'Get-ReportingEndpointEvidence', 'Get-ReportingTransportFailureEvidence')) {
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
using System.Text.RegularExpressions;
namespace MemLabs {
    public sealed class ReportingHttpFixture : IDisposable {
        private readonly TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        private readonly ManualResetEvent stopping = new ManualResetEvent(false);
        private readonly CountdownEvent workers = new CountdownEvent(1);
        private readonly Thread acceptThread;
        public readonly ConcurrentQueue<string> Requests = new ConcurrentQueue<string>();
        public readonly ConcurrentQueue<string> Errors = new ConcurrentQueue<string>();
        public volatile bool StallApi = true;
        public volatile bool SoapCatalog = false;
        public int ReportCount = 1;
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
                    string soapAction = "";
                    int bodyLength = 0;
                    do {
                        line = reader.ReadLine();
                        if (line != null && line.StartsWith("SOAPAction:", StringComparison.OrdinalIgnoreCase)) soapAction = line;
                        if (line != null && line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) bodyLength = Int32.Parse(line.Substring(15).Trim());
                    } while (!String.IsNullOrEmpty(line));
                    if (SoapCatalog && path.StartsWith("/ReportServer/ReportService2010.asmx", StringComparison.OrdinalIgnoreCase)) {
                        string response;
                        if (!first.StartsWith("POST ", StringComparison.Ordinal)) response = Wsdl();
                        else {
                            if (bodyLength < 0 || bodyLength > 131072) throw new InvalidDataException("Invalid fixture SOAP body length.");
                            char[] bodyChars = new char[bodyLength];
                            int used = 0;
                            while (used < bodyChars.Length) {
                                int count = reader.Read(bodyChars, used, bodyChars.Length - used);
                                if (count == 0) throw new EndOfStreamException();
                                used += count;
                            }
                            string requestBody = new String(bodyChars);
                            string operation = soapAction.Contains("GetItemType") ? "GetItemType" : "ListChildren";
                            string result;
                            if (operation == "GetItemType") result = "Folder";
                            else {
                                result = "";
                                if (Regex.IsMatch(requestBody, "<(?:\\w+:)?ItemPath>\\s*/\\s*</")) result = CatalogItem("ConfigMgr_PS1", "/ConfigMgr_PS1", "Folder");
                                else for (int i = 0; i < ReportCount; i++) result += CatalogItem("Report" + i, "/ConfigMgr_PS1/Hardware/Report" + i, "Report");
                            }
                            response = "<soap:Envelope xmlns:soap='http://schemas.xmlsoap.org/soap/envelope/'><soap:Body><" +
                                operation + "Response xmlns='urn:memlabs:reporting'><" + operation + "Result>" + result +
                                "</" + operation + "Result></" + operation + "Response></soap:Body></soap:Envelope>";
                        }
                        byte[] payload = Encoding.UTF8.GetBytes(response);
                        byte[] soapHeader = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/xml; charset=utf-8\r\nContent-Length: " + payload.Length + "\r\nConnection: close\r\n\r\n");
                        stream.Write(soapHeader,0,soapHeader.Length); stream.Write(payload,0,payload.Length); stream.Flush();
                        return;
                    }
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
        private string CatalogItem(string name, string path, string type) {
            return "<CatalogItem><Name>" + name + "</Name><Path>" + path + "</Path><TypeName>" + type + "</TypeName></CatalogItem>";
        }
        private string Wsdl() {
            StringBuilder xml = new StringBuilder("<wsdl:definitions xmlns:wsdl='http://schemas.xmlsoap.org/wsdl/' xmlns:s='http://www.w3.org/2001/XMLSchema' xmlns:soap='http://schemas.xmlsoap.org/wsdl/soap/' xmlns:tns='urn:memlabs:reporting' targetNamespace='urn:memlabs:reporting'>");
            xml.Append("<wsdl:types><s:schema elementFormDefault='qualified' targetNamespace='urn:memlabs:reporting'><s:complexType name='CatalogItem'><s:sequence><s:element name='Name' type='s:string'/><s:element name='Path' type='s:string'/><s:element name='TypeName' type='s:string'/></s:sequence></s:complexType><s:complexType name='ArrayOfCatalogItem'><s:sequence><s:element name='CatalogItem' type='tns:CatalogItem' minOccurs='0' maxOccurs='unbounded'/></s:sequence></s:complexType>");
            foreach (string op in new string[] {"GetItemType", "ListChildren"}) {
                xml.Append("<s:element name='" + op + "'><s:complexType><s:sequence><s:element name='ItemPath' type='s:string'/>" +
                    (op == "ListChildren" ? "<s:element name='Recursive' type='s:boolean'/>" : "") +
                    "</s:sequence></s:complexType></s:element><s:element name='" + op + "Response'><s:complexType><s:sequence><s:element name='" + op + "Result' type='" +
                    (op == "ListChildren" ? "tns:ArrayOfCatalogItem" : "s:string") + "'/></s:sequence></s:complexType></s:element>");
            }
            xml.Append("</s:schema></wsdl:types>");
            foreach (string op in new string[] {"GetItemType", "ListChildren"})
                foreach (string suffix in new string[] {"", "Response"})
                    xml.Append("<wsdl:message name='" + op + suffix + "'><wsdl:part name='parameters' element='tns:" + op + suffix + "'/></wsdl:message>");
            xml.Append("<wsdl:portType name='ReportingSoap'>");
            foreach (string op in new string[] {"GetItemType", "ListChildren"})
                xml.Append("<wsdl:operation name='" + op + "'><wsdl:input message='tns:" + op + "'/><wsdl:output message='tns:" + op + "Response'/></wsdl:operation>");
            xml.Append("</wsdl:portType><wsdl:binding name='ReportingSoap' type='tns:ReportingSoap'><soap:binding transport='http://schemas.xmlsoap.org/soap/http' style='document'/>");
            foreach (string op in new string[] {"GetItemType", "ListChildren"})
                xml.Append("<wsdl:operation name='" + op + "'><soap:operation soapAction='urn:memlabs:reporting/" + op + "'/><wsdl:input><soap:body use='literal'/></wsdl:input><wsdl:output><soap:body use='literal'/></wsdl:output></wsdl:operation>");
            xml.Append("</wsdl:binding><wsdl:service name='Reporting'><wsdl:port name='ReportingSoap' binding='tns:ReportingSoap'><soap:address location='http://127.0.0.1:" + Port + "/ReportServer/ReportService2010.asmx'/></wsdl:port></wsdl:service></wsdl:definitions>");
            return xml.ToString();
        }
    }
}
'@
}
if ($PSVersionTable.PSEdition -eq 'Core') {
    & {
        . (Import-TestFunction -Path (Join-Path $RootPath 'Common.ps1') -Name 'Invoke-VmCommand')
        . (Join-Path $PSScriptRoot 'Common.ReportingDiagnostics.ps1')
        . (Import-TestFunction -Path (Join-Path $RootPath 'common\Common.ScriptBlocks.ps1') -Name 'Get-MemLabsMemoryDiagnosticProbe')
        $server = [MemLabs.ReportingHttpFixture]::new()
        $server.StallApi = $false
        $remote = $null
        $messages = [System.Collections.Generic.List[string]]::new()
        $password = [System.Security.SecureString]::new()
        $password.AppendChar([char]120)
        $Common = [pscustomobject]@{ LocalAdmin = [pscredential]::new('fixture-admin', $password) }
        function Write-Log {
            param($Text, [switch]$LogOnly, [switch]$Failure, [switch]$Warning, [switch]$Verbose)
            $messages.Add("$Text")
        }
        function Get-VMNote { param($VMName); [pscustomobject]@{ domain = 'example' } }
        function Get-VmSession {
            param($VmName, $VmDomainName, $VmDomainAccount, $ShowVMSessionError, $MaxRetries, $LocalOnly, $RequireDomainIdentity, $Diagnostics, $Quiet)
            if (-not $RequireDomainIdentity) { throw 'Reporting transport lost its identity requirement.' }
            $remote
        }
        function Enter-VmSessionInflight { param($Session, $DisplayName); 'remoting-fixture' }
        function Exit-VmSessionInflight { param($Token) }
        function Write-VmJobLedger { param($Op, $Job, $VmName, $DisplayName, $Detail) }
        function Set-VmSessionPipelineEvent { param($Session, $Kind, $Op) }
        function Remove-VmSessionFromCache { param($VmName, [switch]$LeakSession, $AbandonedJob) }
        try {
            $remote = New-PSSession -UseWindowsPowerShell -Name "MemLabs-Reporting-$([guid]::NewGuid().ToString('N'))" -ErrorAction Stop
            Invoke-Command -Session $remote -ScriptBlock {
                function global:Invoke-MemLabsBoundedPowerShell { throw 'Fixture stale worker helper reused' }
            } -ErrorAction Stop
            $source = ''
            foreach ($name in @('Invoke-ReportingWebRequest','Get-ReportingPortalEvidence')) {
                $source += "function $name { $((Get-Command $name).Definition) }`n"
            }
            $probe = { param($Source,$Uri); . ([scriptblock]::Create($Source)); Get-ReportingPortalEvidence -PortalUri ([uri]$Uri) }
            $result = Invoke-ReportingGuestAlternative -VMName RP-TEST -Domain example -Addresses @('localhost') `
                -Credential $Common.LocalAdmin -Probe $probe -ProbeArguments $source,"http://127.0.0.1:$($server.Port)/Reports/" `
                -PrimitiveSource $source -Name Portal -TimeoutSeconds 20
            if ($result.Error -or $result.Method -ne 'PowerShellDirect' -or $result.Output.RestApi.StatusCode -ne 200) {
                throw "Real isolated guest probe failed: $($result.Error)"
            }
            $context = Get-ReportingTransportFailureEvidence -VMName RP-TEST -Domain example -StartedAt ([DateTime]::UtcNow.ToString('o'))
            if ($context.Guest.ComputerName -ne $env:COMPUTERNAME -or $context.Guest.EventLogs.Count -ne 3 -or -not $context.Guest.Memory) {
                throw 'Real remoting did not return the post-failure crash/memory evidence shape.'
            }
        }
        catch {
            $testError = $_
            if ($testError.Exception.Message -match 'Failure evidence: (.+\.json)$') {
                Remove-Item -LiteralPath $Matches[1] -Force -ErrorAction Stop
            }
            throw "Real Windows PowerShell remoting collection failed: $($testError.Exception.Message); transport=$($messages -join '; ')"
        }
        finally {
            if ($remote) { Remove-PSSession -Session $remote -ErrorAction Stop }
            $server.Dispose()
        }
        Write-Host 'PASS -- isolated guest probes execute through the actual shared asynchronous transport without nested guest workers.'
    }
    & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -File $PSCommandPath -RootPath $RootPath
    if ($LASTEXITCODE -ne 0) { throw 'Reporting guest-runtime regression failed in Windows PowerShell 5.1.' }
    return
}
$server = [MemLabs.ReportingHttpFixture]::new()
try {
    $uri = [uri] "http://127.0.0.1:$($server.Port)/ReportServer"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $blocked = Get-ReportingEndpointEvidence -ServerUri $uri -SiteCode PS1 -TimeoutSeconds 6
    $clock.Stop()
    $portalProbe = $blocked.Probes | Where-Object { $_.Name -eq 'Portal' }
    if (-not $portalProbe.TimedOut -or $blocked.PortalError -notmatch '6-second wall-clock limit' -or
        $portalProbe.LastRequest -notmatch '/Reports/api/v2.0/CatalogItems' -or
        $blocked.ReportServerPage.StatusCode -ne 200 -or $clock.Elapsed.TotalSeconds -ge 30) {
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
$result = Invoke-VmCommand -VmName RP-TEST -VmDomainName example -ScriptBlock { 1 } `
    -DisplayName 'Isolated timeout regression' -AsJob -TimeoutSeconds 40 -SuppressLog
if (-not $result.TimedOut -or ($result.ErrorDetails -join ' ') -notmatch '40s' -or -not $transport.StopRequested -or -not $transport.Evicted -or
    -not ($transport.Logs | Where-Object { $_ -match 'Timeout autopsy.*Reading web response' })) {
    throw "Actual Invoke-VmCommand timeout was not surfaced or safely cancelled: $($transport | ConvertTo-Json -Compress)"
}
Write-Host 'PASS -- real reporting HTTP stalls are bounded, partial evidence survives, workers stop, and shared transport timeouts remain explicit.'
