#requires -Version 7.4
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path $PSScriptRoot 'Common.Control.ps1')
Initialize-MemLabsControlTransport

function Get-ControlMcpTools {
    $emptySchema = @{ type = 'object'; properties = @{}; additionalProperties = $false }
    $vmSchema = @{
        type = 'object'; properties = @{ vmId = @{ type = 'string'; format = 'uuid'; description = 'Exact local VM ID returned by memlabs_list_vms.' } }
        required = @('vmId'); additionalProperties = $false
    }
    @(
        @{
            name = 'memlabs_status'; description = 'Read the explicitly started MemLabs worker status. Never elevates or starts the worker.'
            inputSchema = $emptySchema; annotations = @{ readOnlyHint = $true; openWorldHint = $false }
        },
        @{
            name = 'memlabs_list_vms'; description = 'List local Hyper-V VM IDs and states without exposing guest credentials or VM notes.'
            inputSchema = @{ type = 'object'; properties = @{ offset = @{ type = 'integer'; minimum = 0 }; limit = @{ type = 'integer'; minimum = 1; maximum = 100 } }; additionalProperties = $false }
            annotations = @{ readOnlyHint = $true; openWorldHint = $false }
        },
        @{
            name = 'memlabs_start_vm'; description = 'Start one Off local VM by exact ID. Returns an operation ID; query memlabs_get_operation for the verified result.'
            inputSchema = $vmSchema; annotations = @{ readOnlyHint = $false; destructiveHint = $false; openWorldHint = $false }
        },
        @{
            name = 'memlabs_stop_vm'; description = 'Request a graceful shutdown of one Running VM after user confirmation. Never force-powers off, deletes, or removes a domain.'
            inputSchema = @{
                type = 'object'; properties = @{ vmId = @{ type = 'string'; format = 'uuid' }; confirm = @{ type = 'boolean'; const = $true } }
                required = @('vmId', 'confirm'); additionalProperties = $false
            }
            annotations = @{ readOnlyHint = $false; destructiveHint = $true; openWorldHint = $false }
        },
        @{
            name = 'memlabs_get_operation'; description = 'Read a running or recently completed VM operation and its independently verified outcome.'
            inputSchema = @{
                type = 'object'; properties = @{ operationId = @{ type = 'string'; format = 'uuid' } }
                required = @('operationId'); additionalProperties = $false
            }
            annotations = @{ readOnlyHint = $true; openWorldHint = $false }
        }
    )
}

$initialized = $false
while ($true) {
    $id = $null
    $notification = $false
    $errorCode = -32700
    try {
        $line = [MemLabs.Control.Transport]::ReadLine([Console]::In)
        if ($null -eq $line) { break }
        $request = $line | ConvertFrom-Json -AsHashtable -Depth 20 -ErrorAction Stop
        $errorCode = -32600
        if ($request -isnot [Collections.IDictionary] -or $request.jsonrpc -cne '2.0' -or $request.method -isnot [string]) {
            throw 'Expected a JSON-RPC 2.0 request object.'
        }
        $notification = -not $request.Contains('id')
        if (-not $notification) {
            if ($request.id -isnot [string] -and $request.id -isnot [long] -and $request.id -isnot [int]) { throw 'Request ID must be a string or integer.' }
            $id = $request.id
        }
        $parameters = if ($request.Contains('params')) { $request.params } else { @{} }
        $errorCode = -32602
        if ($parameters -isnot [Collections.IDictionary]) { throw 'Request parameters must be an object.' }
        $value = $null
        switch -CaseSensitive ($request.method) {
            'initialize' {
                if ($notification) { throw 'Initialization requires a request ID.' }
                Assert-MemLabsControlKeys -Object $parameters -Allowed @('protocolVersion', 'capabilities', 'clientInfo', '_meta') -Required @('protocolVersion', 'capabilities', 'clientInfo')
                if ($parameters.protocolVersion -isnot [string] -or $parameters.capabilities -isnot [Collections.IDictionary] -or
                    $parameters.clientInfo -isnot [Collections.IDictionary]) { throw 'Invalid MCP initialization parameters.' }
                $initialized = $true
                $value = @{
                    protocolVersion = '2025-11-25'
                    capabilities = @{ tools = @{ listChanged = $false } }
                    serverInfo = @{ name = 'memlabs'; version = '1.0.0' }
                    instructions = 'The worker must be started by the user. VM changes require explicit authorization. Deployment, deletion and arbitrary scripts are not available.'
                }
            }
            'notifications/initialized' { }
            'notifications/cancelled' { }
            'ping' { $value = @{} }
            'tools/list' {
                if (-not $initialized) { throw 'Initialize the MCP server first.' }
                $value = @{ tools = @(Get-ControlMcpTools) }
            }
            'tools/call' {
                if (-not $initialized -or $notification) { throw 'Tool calls require initialization and a request ID.' }
                Assert-MemLabsControlKeys -Object $parameters -Allowed @('name', 'arguments', '_meta') -Required @('name')
                $mapping = @{
                    memlabs_status = 'status'; memlabs_list_vms = 'inventory'; memlabs_start_vm = 'start_vm'
                    memlabs_stop_vm = 'stop_vm'; memlabs_get_operation = 'operation'
                }
                if ($parameters.name -isnot [string] -or $parameters.name -cnotin $mapping.Keys) { throw 'Unknown MemLabs tool.' }
                $arguments = if ($parameters.Contains('arguments')) { $parameters.arguments } else { @{} }
                if ($arguments -isnot [Collections.IDictionary]) { throw 'Tool arguments must be an object.' }
                $method = $mapping[$parameters.name]
                Assert-MemLabsControlArguments -Method $method -Arguments $arguments
                try {
                    $result = Invoke-MemLabsControlRequest -Method $method -Arguments $arguments
                    $failed = $false
                }
                catch {
                    $result = [pscustomobject]@{ error = $_.Exception.Message }
                    $failed = $true
                    [Console]::Error.WriteLine($_.Exception.Message)
                }
                $value = @{
                    content = @(@{ type = 'text'; text = ($result | ConvertTo-Json -Depth 15 -Compress) })
                    structuredContent = $result
                    isError = $failed
                }
            }
            default {
                if ($notification) { continue }
                [Console]::Out.WriteLine((@{ jsonrpc = '2.0'; id = $id; error = @{ code = -32601; message = 'Method not found.' } } | ConvertTo-Json -Depth 6 -Compress))
                continue
            }
        }
        if (-not $notification) {
            [Console]::Out.WriteLine((@{ jsonrpc = '2.0'; id = $id; result = $value } | ConvertTo-Json -Depth 20 -Compress))
        }
    }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        if (-not $notification) {
            [Console]::Out.WriteLine((@{ jsonrpc = '2.0'; id = $id; error = @{ code = $errorCode; message = $_.Exception.Message } } | ConvertTo-Json -Depth 6 -Compress))
        }
    }
}
