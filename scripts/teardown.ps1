#Requires -Version 7.2
<#
.SYNOPSIS
    Removes what the demo created: the Azure resource group (MDP pool, ACI agent, registry, identity,
    Dev Center), the ACI agent's registration PAT, the ACI agent pool and, optionally, the project.

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

if ($PSCmdlet.ShouldProcess("$($state.resourceGroup) in subscription $($state.subscriptionId)", 'Delete resource group')) {
    Write-Step "Deleting resource group $($state.resourceGroup)"
    $exists = Invoke-AzCli group exists --subscription $state.subscriptionId --name $state.resourceGroup
    if ($exists -eq 'true') { Invoke-AzCli group delete --subscription $state.subscriptionId --name $state.resourceGroup --yes -o none }
}

if ($state['aciPatAuthorizationId'] -and $PSCmdlet.ShouldProcess('ACI agent registration PAT', 'Revoke')) {
    Write-Step 'Revoking the ACI agent registration PAT'
    Invoke-Ado -Method DELETE -Uri "https://vssps.dev.azure.com/$organization/_apis/tokens/pats?authorizationId=$($state.aciPatAuthorizationId)&api-version=7.1-preview.1" | Out-Null
    $state.Remove('aciPatAuthorizationId')
    Save-DemoState $state
}

if ($state['aciPoolId'] -and $PSCmdlet.ShouldProcess("Agent pool '$($state.aciPool)'", 'Delete')) {
    Write-Step "Deleting agent pool '$($state.aciPool)'"
    try { Invoke-Ado -Method DELETE -Uri "$orgUrl/_apis/distributedtask/pools/$($state.aciPoolId)?api-version=7.1" | Out-Null }
    catch { Write-Warning "Could not delete the ACI agent pool: $($_.Exception.Message)" }
}

$mdpPool = (Invoke-Ado -Uri "$orgUrl/_apis/distributedtask/pools?poolName=$([uri]::EscapeDataString($state.mdpPool))&api-version=7.1").value
if ($mdpPool) { Write-Warning "Azure DevOps still lists pool '$($state.mdpPool)'. Remove it under Organization settings > Agent pools if it remains." }

if ($DeleteProject -and $PSCmdlet.ShouldProcess("Project '$($state.project)'", 'Delete')) {
    Write-Step "Deleting project '$($state.project)'"
    $project = Invoke-Ado -Uri "$orgUrl/_apis/projects/$projectPath`?api-version=7.1"
    Invoke-Ado -Method DELETE -Uri "$orgUrl/_apis/projects/$($project.id)?api-version=7.1" | Out-Null
}

Remove-Item -Path $script:StatePath -Force -ErrorAction SilentlyContinue
Write-Step 'Teardown complete'
