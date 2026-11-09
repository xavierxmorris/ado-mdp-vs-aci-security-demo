#Requires -Version 7.2
<#
.SYNOPSIS
    Removes what the demo created: the policy assignments and definitions, the Azure resource group
    (MDP pools, ACI agents, registry, identities, Dev Center), the ACI agents' registration PATs, the
    self-hosted agent pools, the WIF service connection and, optionally, the project.

.EXAMPLE
    ./scripts/teardown.ps1 -DeleteProject
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $DeleteProject
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-DemoState
if (-not $state['organization']) { throw 'No .demo-state.json found; nothing to remove.' }
$organization = $state.organization
$orgUrl = "https://dev.azure.com/$organization"
$projectPath = [uri]::EscapeDataString($state.project)
$subscription = $state.subscriptionId

$policyNames = @($state['policyDefinitionNames'] | Where-Object { $_ })
if ($policyNames -and $PSCmdlet.ShouldProcess(($policyNames -join ', '), 'Delete policy assignments and definitions')) {
    Write-Step 'Deleting the Azure Policy baseline'
    foreach ($name in $policyNames) {
        az policy assignment delete --subscription $subscription --resource-group $state.resourceGroup --name $name -o none 2>$null
        az policy definition delete --subscription $subscription --name $name -o none 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "Deleted $name" } else { Write-Warning "Could not delete policy definition $name" }
    }
    $state.Remove('policyDefinitionNames')
    Save-DemoState $state
}

if ($PSCmdlet.ShouldProcess("$($state.resourceGroup) in subscription $subscription", 'Delete resource group')) {
    Write-Step "Deleting resource group $($state.resourceGroup)"
    $exists = Invoke-AzCli group exists --subscription $subscription --name $state.resourceGroup
    if ($exists -eq 'true') { Invoke-AzCli group delete --subscription $subscription --name $state.resourceGroup --yes -o none }
}

foreach ($agent in 'aci', 'aciOnce') {
    $patId = $state["$($agent)PatAuthorizationId"]
    if ($patId -and $PSCmdlet.ShouldProcess("$agent agent registration PAT", 'Revoke')) {
        Write-Step "Revoking the $agent agent registration PAT"
        Invoke-Ado -Method DELETE -Uri "https://vssps.dev.azure.com/$organization/_apis/tokens/pats?authorizationId=$patId&api-version=7.1-preview.1" | Out-Null
        $state.Remove("$($agent)PatAuthorizationId")
        Save-DemoState $state
    }
    $poolId = $state["$($agent)PoolId"]
    $poolName = $state["$($agent)Pool"]
    if ($poolId -and $PSCmdlet.ShouldProcess("Agent pool '$poolName'", 'Delete')) {
        Write-Step "Deleting agent pool '$poolName'"
        try { Invoke-Ado -Method DELETE -Uri "$orgUrl/_apis/distributedtask/pools/$poolId`?api-version=7.1" | Out-Null }
        catch { Write-Warning "Could not delete agent pool '$poolName': $($_.Exception.Message)" }
    }
}

if ($state['wifServiceConnectionId'] -and -not $DeleteProject -and $PSCmdlet.ShouldProcess('WIF service connection', 'Delete')) {
    Write-Step 'Deleting the WIF service connection'
    $project = Invoke-Ado -Uri "$orgUrl/_apis/projects/$projectPath`?api-version=7.1"
    Invoke-Ado -Method DELETE -Uri "$orgUrl/_apis/serviceendpoint/endpoints/$($state.wifServiceConnectionId)?projectIds=$($project.id)&api-version=7.1" | Out-Null
}

foreach ($poolName in @($state['mdpPool'], $state['mdpStatefulPool']) | Where-Object { $_ }) {
    $remaining = (Invoke-Ado -Uri "$orgUrl/_apis/distributedtask/pools?poolName=$([uri]::EscapeDataString($poolName))&api-version=7.1").value
    if ($remaining) { Write-Warning "Azure DevOps still lists pool '$poolName'. Remove it under Organization settings > Agent pools if it remains." }
}

if ($DeleteProject -and $PSCmdlet.ShouldProcess("Project '$($state.project)'", 'Delete')) {
    Write-Step "Deleting project '$($state.project)' (including its pipelines and service connection)"
    $project = Invoke-Ado -Uri "$orgUrl/_apis/projects/$projectPath`?api-version=7.1"
    Invoke-Ado -Method DELETE -Uri "$orgUrl/_apis/projects/$($project.id)?api-version=7.1" | Out-Null
}

Remove-Item -Path $script:StatePath -Force -ErrorAction SilentlyContinue
Write-Step 'Teardown complete'
