#Requires -Version 7.2
<#
.SYNOPSIS
    Writes DEMO-LINKS.local.md (git-ignored) with the exact Azure DevOps and Azure portal links for this
    deployment, in the order RUN-SHEET.md uses them. Run it after deploy.ps1.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$state = Get-DemoState
if (-not $state['pipelineId']) { throw 'Run ./scripts/deploy.ps1 first.' }
$org = "https://dev.azure.com/$($state.organization)"
$project = [uri]::EscapeDataString($state.project)
$tenant = Invoke-AzCli account show --subscription $state.subscriptionId --query tenantId -o tsv
$mdpPool = (Invoke-Ado -Uri "$org/_apis/distributedtask/pools?poolName=$([uri]::EscapeDataString($state.mdpPool))&api-version=7.1").value | Select-Object -First 1
$latestRun = (Invoke-Ado -Uri "$org/$project/_apis/pipelines/$($state.pipelineId)/runs?api-version=7.1").value |
    Where-Object { $_.result -eq 'succeeded' } | Select-Object -First 1
$resourceGroup = "https://portal.azure.com/#@$tenant/resource/subscriptions/$($state.subscriptionId)/resourceGroups/$($state.resourceGroup)"

$links = @(
    '# Demo links (generated; do not commit)'
    ''
    "Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') by scripts/demo-links.ps1. Follow RUN-SHEET.md; these open each scene directly."
    ''
    '| Scene | Link |'
    '|-------|------|'
    "| 1. Organization agent pools | $org/_settings/agentpools |"
    "| 1. ACI pool: Agents tab | $org/_settings/agentpools?poolId=$($state.aciPoolId)&view=agents |"
    "| 1. MDP pool: Jobs tab | $org/_settings/agentpools?poolId=$($mdpPool.id)&view=jobs |"
    "| 1. Project agent pools | $org/$project/_settings/agentqueues |"
    "| 2. ACI container group: Containers | $resourceGroup/providers/Microsoft.ContainerInstance/containerGroups/aci-azp-agent/containers |"
    "| 3. MDP pool: Overview | $resourceGroup/providers/Microsoft.DevOpsInfrastructure/pools/$($state.mdpPool)/overview |"
    "| 4. Pipeline (Run pipeline) | $org/$project/_build?definitionId=$($state.pipelineId) |"
)
if ($latestRun) {
    $links += "| 5. Last successful run (fallback) | $org/$project/_build/results?buildId=$($latestRun.id)&view=results |"
}
$links += "| Resource group | $resourceGroup/overview |"
if ($state['deepDive']) {
    $mdpQueue = $state['mdpQueueId']
    $links += @(
        ''
        '## Deep-dive links'
        ''
        '| Scene | Link |'
        '|-------|------|'
        "| 6. ACI --once container group: Containers | $resourceGroup/providers/Microsoft.ContainerInstance/containerGroups/aci-azp-agent-once/containers |"
        "| 7. MDP with agent reuse: Overview | $resourceGroup/providers/Microsoft.DevOpsInfrastructure/pools/$($state['mdpStatefulPool'])/overview |"
        "| 7. Azure Policy: Compliance | https://portal.azure.com/#@$tenant/view/Microsoft_Azure_Policy/PolicyMenuBlade/~/Compliance |"
        "| 8. Unapproved pipeline | $org/$project/_build?definitionId=$($state['unapprovedPipelineId']) |"
        "| 8. MDP pool: Security (pipeline permissions) | $org/$project/_settings/agentqueues?queueId=$mdpQueue&view=security |"
        "| 9. WIF service connection | $org/$project/_settings/adminservices?resourceId=$($state['wifServiceConnectionId']) |"
        "| 10. Organization auditing | $org/_settings/audit |"
    )
}
$configDir = if ($env:AZURE_CONFIG_DIR) { "`$env:AZURE_CONFIG_DIR = '$env:AZURE_CONFIG_DIR'; " } else { '' }
$links += @(
    ''
    '## Commands (run from the repository folder)'
    ''
    '```powershell'
    "$($configDir)./scripts/run-probe.ps1 -ProofOfImpact   # warm-up run without the browser"
    "$($configDir)./scripts/run-probe.ps1 -ProofOfImpact -DeepDive   # deep-dive evidence (about 10 minutes)"
    "$($configDir)./scripts/audit-evidence.ps1   # audit events for the demo pools"
    "$($configDir)az container restart --subscription $($state.subscriptionId) -g $($state.resourceGroup) -n aci-azp-agent   # if aci-agent-1 is offline"
    "$($configDir)./scripts/teardown.ps1 -DeleteProject   # after the demo"
    '```'
)

$path = Join-Path $script:RepoRoot 'DEMO-LINKS.local.md'
$links | Set-Content -Path $path -Encoding utf8
Get-Content $path
Write-Host "`nSaved $path"
