# Shared helpers for the demo scripts. Dot-source this file; it does nothing on its own.
# Azure DevOps calls use a Microsoft Entra token from the signed-in Azure CLI identity, never a PAT.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:StatePath = Join-Path $script:RepoRoot '.demo-state.json'
$script:AdoResource = '499b84ac-1321-427f-aa17-267ca6975798'
$script:AdoToken = $null
$script:AdoTokenExpires = [datetime]::MinValue

function Write-Step([string] $Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-AzCli {
    # Runs az and throws on failure. Never pass secrets as arguments; they would appear here.
    $output = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args -join ' ') failed (exit code $LASTEXITCODE)." }
    $output
}

function Get-AdoHeaders {
    if (-not $script:AdoToken -or $script:AdoTokenExpires -lt (Get-Date).AddMinutes(5)) {
        $token = Invoke-AzCli account get-access-token --resource $script:AdoResource -o json | ConvertFrom-Json
        $script:AdoToken = $token.accessToken
        $script:AdoTokenExpires = [datetime]$token.expiresOn
    }
    @{ Authorization = "Bearer $script:AdoToken" }
}

function Invoke-Ado {
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)] [string] $Uri,
        $Body
    )
    $request = @{ Method = $Method; Uri = $Uri; Headers = (Get-AdoHeaders) }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = $Body | ConvertTo-Json -Depth 20 -Compress
        $request.ContentType = 'application/json'
    }
    Invoke-RestMethod @request
}

function Get-DemoState {
    if (Test-Path $script:StatePath) { Get-Content -Raw $script:StatePath | ConvertFrom-Json -AsHashtable } else { @{} }
}

function Save-DemoState([hashtable] $State) {
    # Identifiers only (no secrets). The file is git-ignored.
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $script:StatePath -Encoding utf8
}

function Get-AdoQueue([string] $OrgUrl, [string] $Project, [string] $Name) {
    $uri = "$OrgUrl/$Project/_apis/distributedtask/queues?queueNames=$([uri]::EscapeDataString($Name))&api-version=7.1-preview.1"
    (Invoke-Ado -Uri $uri).value | Select-Object -First 1
}
