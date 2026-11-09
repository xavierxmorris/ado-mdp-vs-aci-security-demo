#Requires -Version 7.2
<#
.SYNOPSIS
    Lists the Azure DevOps audit events that matter for self-hosted agents: agent pools created, agents
    registered (Library.AgentAdded), and service connections created or used. Saves results/audit-<date>.md.

.DESCRIPTION
    Every self-hosted agent registration appears as Library.AgentAdded. An unexpected agent in a pool that
    runs production deployments is what a stolen registration PAT would produce, so alert on it.
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 90)] [int] $Days = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-DemoState
if (-not $state['organization']) { throw 'Run ./scripts/deploy.ps1 first.' }
$start = (Get-Date).ToUniversalTime().AddDays(-$Days).ToString('o')
$entries = @()
$continuation = $null
do {
    $uri = "https://auditservice.dev.azure.com/$($state.organization)/_apis/audit/auditlog?startTime=$start&batchSize=500&api-version=7.1-preview.1"
    if ($continuation) { $uri += "&continuationToken=$continuation" }
    $page = Invoke-Ado -Uri $uri
    $entries += $page.decoratedAuditLogEntries
    $continuation = $page.continuationToken
} while ($page.hasMore -and $entries.Count -lt 5000)

$names = @($state['aciPool'], $state['aciOncePool'], $state['mdpPool'], $state['mdpStatefulPool'], 'sc-wif-demo') | Where-Object { $_ }
$pattern = ($names | ForEach-Object { [regex]::Escape($_) }) -join '|'
$relevant = $entries |
    Where-Object { $_.actionId -match '^Library\.(Agent|ServiceConnection)' -and $_.details -match $pattern } |
    Sort-Object timestamp

$lines = @(
    "# Azure DevOps audit evidence ($(Get-Date -Format 'yyyy-MM-dd'), last $Days day(s))"
    ''
    'Events for the demo pools and the WIF service connection. `Library.AgentAdded` is the one to alert on.'
    ''
    '| Time (UTC) | Event | Details |'
    '|---|---|---|'
)
$lines += $relevant | ForEach-Object { "| $(([datetime]$_.timestamp).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) | $($_.actionId) | $($_.details -replace '\|', '/') |" }
$lines += ''
$lines += ($relevant | Group-Object actionId | ForEach-Object { "- $($_.Name): $($_.Count)" })

$path = Join-Path $script:RepoRoot "results/audit-$(Get-Date -Format 'yyyy-MM-dd').md"
$lines | Set-Content -Path $path -Encoding utf8
Get-Content $path
Write-Host "`nSaved $path"
