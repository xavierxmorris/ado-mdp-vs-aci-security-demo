#Requires -Version 7.2
<#
.SYNOPSIS
    Builds the MDP vs ACI security demo in Azure and Azure DevOps, including the optional deep-dive scenes.

.DESCRIPTION
    Safe to re-run: existing resources are reused. Uses the signed-in Azure CLI identity for Azure and,
    through Microsoft Entra tokens, for Azure DevOps. The only PATs created are the registration tokens that
    Microsoft's documented container agent needs; those tokens are what the demo examines.

    Core: an ACI agent (Microsoft's documented container) and a Managed DevOps Pool (fresh agents).
    Deep dive (skip with -SkipDeepDive): an ACI agent run with --once, an MDP pool that reuses agents,
    a pipeline that isn't authorised to use the pool, a workload identity federation (WIF) service
    connection with Reader on the demo resource group, and an Azure Policy baseline in audit mode.

    Needs: Owner (or Contributor + Role Based Access Control Administrator + Resource Policy Contributor) on the
    subscription, and Project Collection Administrator in an Azure DevOps organisation in the same Entra tenant.

.EXAMPLE
    ./scripts/deploy.ps1 -Organization contoso -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    # A second deployment in the same subscription (another organisation). MDP pool names are globally
    # unique in Azure, so give the resource a new name and keep the Azure DevOps pool name with an alias.
    # Choose a VM size whose MDP quota family still has free cores. Deploy the deep dive in one instance
    # only (-SkipDeepDive here): its MDP pool name is global and its policy definitions are per subscription.
    ./scripts/deploy.ps1 -Organization contoso-two -SubscriptionId <id> -ResourceGroup rg-mdp-vs-aci-two `
        -MdpPoolName mdp-security-demo-two -MdpPoolAlias mdp-security-demo -MdpSku Standard_D2as_v5 -SkipDeepDive
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Organization,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $Project = 'mdp-vs-aci-security',
    [string] $Location = 'australiaeast',
    [string] $ResourceGroup = 'rg-mdp-vs-aci-security',
    [string] $AciPoolName = 'aci-selfhosted-demo',
    [string] $AciOncePoolName = 'aci-once-demo',
    # Azure resource name of the MDP pool. Must be globally unique in Azure.
    [string] $MdpPoolName = 'mdp-security-demo',
    # Azure DevOps agent pool name, when it must differ from -MdpPoolName (pool alias).
    [string] $MdpPoolAlias = '',
    # Agent VM size. Pick one whose MDP quota family has free cores in -Location.
    [ValidatePattern('^Standard_[A-Za-z0-9_]+$')] [string] $MdpSku = 'Standard_D2ads_v5',
    # Deep dive: MDP pool that reuses agents. Also globally unique in Azure.
    [string] $MdpStatefulPoolName = 'mdp-stateful-demo',
    [string] $WifServiceConnectionName = 'sc-wif-demo',
    [ValidateRange(0, 2)] [int] $MdpStandbyAgents = 1,
    [ValidateRange(1, 30)] [int] $PatLifetimeDays = 7,
    [switch] $SkipDeepDive,
    # Replace the ACI agents' registration PATs (the old ones are revoked).
    [switch] $RotateAciToken,
    [switch] $RebuildImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$deepDive = -not $SkipDeepDive
$orgUrl = "https://dev.azure.com/$Organization"
$projectPath = [uri]::EscapeDataString($Project)
# The name Azure DevOps shows for the MDP pool: the alias if set, otherwise the resource name.
$mdpAdoPoolName = if ($MdpPoolAlias) { $MdpPoolAlias } else { $MdpPoolName }
# Deep dive: a VM family separate from the default one, so both pools fit the default 5-core quotas.
$mdpStatefulSku = 'Standard_E2as_v4'
$state = Get-DemoState
$state.organization = $Organization
$state.project = $Project
$state.subscriptionId = $SubscriptionId
$state.resourceGroup = $ResourceGroup
$state.aciPool = $AciPoolName
$state.mdpPool = $mdpAdoPoolName
$state.mdpPoolResource = $MdpPoolName
$state.deepDive = $deepDive
Save-DemoState $state

function Initialize-SelfHostedPool([string] $Name) {
    $pool = (Invoke-Ado -Uri "$orgUrl/_apis/distributedtask/pools?poolName=$([uri]::EscapeDataString($Name))&api-version=7.1").value | Select-Object -First 1
    if (-not $pool) {
        # autoProvision = false: the pool is not added to every project in the organisation.
        $pool = Invoke-Ado -Method POST -Uri "$orgUrl/_apis/distributedtask/pools?api-version=7.1" -Body @{
            name = $Name; autoProvision = $false; autoUpdate = $true; poolType = 'automation'
        }
    }
    $queue = Get-AdoQueue $orgUrl $projectPath $Name
    if (-not $queue) {
        $queue = Invoke-Ado -Method POST -Uri "$orgUrl/$projectPath/_apis/distributedtask/queues?authorizePipelines=false&api-version=7.1-preview.1" -Body @{
            name = $Name; pool = @{ id = $pool.id }
        }
    }
    Write-Host "Pool '$Name': id $($pool.id), project queue $($queue.id)"
    @{ pool = $pool; queue = $queue }
}

function Remove-RegistrationPat([string] $AuthorizationId) {
    if (-not $AuthorizationId) { return }
    Invoke-Ado -Method DELETE -Uri "https://vssps.dev.azure.com/$Organization/_apis/tokens/pats?authorizationId=$AuthorizationId&api-version=7.1-preview.1" | Out-Null
    Write-Host 'Revoked the previous registration PAT'
}

function Wait-OnlineAgent([int] $PoolId, [string] $PoolName, [string] $Hint) {
    $deadline = (Get-Date).AddMinutes(10)
    do {
        Start-Sleep -Seconds 15
        $online = (Invoke-Ado -Uri "$orgUrl/_apis/distributedtask/pools/$PoolId/agents?api-version=7.1").value | Where-Object status -eq 'online'
    } until ($online -or (Get-Date) -gt $deadline)
    if (-not $online) { throw "No online agent in '$PoolName' after 10 minutes. Check: $Hint" }
    Write-Host "Online in '$PoolName': $(@($online.name) -join ', ')"
}

function Deploy-AciAgent {
    param([string] $Key, [string] $ContainerGroupName, [hashtable] $Pool, [string] $AgentName, [bool] $RunOnce)
    $exists = az container show --subscription $SubscriptionId --resource-group $ResourceGroup --name $ContainerGroupName --query name -o tsv 2>$null
    $previousPat = $state["$($Key)PatAuthorizationId"]
    if ($exists -and -not $RotateAciToken) {
        Write-Host "$ContainerGroupName already deployed; keeping its registration PAT. Use -RotateAciToken to replace it."
    } else {
        $created = Invoke-Ado -Method POST -Uri "https://vssps.dev.azure.com/$Organization/_apis/tokens/pats?api-version=7.1-preview.1" -Body @{
            displayName = "$Key-agent-registration ($Project demo)"
            scope       = 'vso.agentpools_manage'
            validTo     = (Get-Date).ToUniversalTime().AddDays($PatLifetimeDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
            allOrgs     = $false
        }
        if ($created.patTokenError -and $created.patTokenError -ne 'none') { throw "PAT creation failed: $($created.patTokenError)" }
        $state["$($Key)PatAuthorizationId"] = $created.patToken.authorizationId
        $state["$($Key)PatValidTo"] = $created.patToken.validTo
        Save-DemoState $state
        Write-Host "Created PAT for $ContainerGroupName (Agent Pools: read & manage), valid to $($created.patToken.validTo); value not displayed"

        # Pass the PAT through a short-lived parameters file, not a command-line argument.
        $parameterFile = Join-Path ([IO.Path]::GetTempPath()) "aci-$([guid]::NewGuid()).parameters.json"
        try {
            @{
                '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
                contentVersion = '1.0.0.0'
                parameters     = @{ azpToken = @{ value = $created.patToken.token } }
            } | ConvertTo-Json -Depth 5 | Set-Content -Path $parameterFile -Encoding utf8
            Invoke-AzCli deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
                --name "$ContainerGroupName-deployment" --template-file (Join-Path $script:RepoRoot 'infra/aci.bicep') `
                --parameters "@$parameterFile" `
                --parameters organizationUrl=$orgUrl aciPoolName=$($Pool.pool.name) image=$image registryLoginServer=$loginServer `
                pullIdentityId=$pullIdentityId containerGroupName=$ContainerGroupName agentName=$AgentName runOnce=$($RunOnce.ToString().ToLowerInvariant()) `
                -o none
        } finally {
            Remove-Item $parameterFile -Force -ErrorAction SilentlyContinue
            $created = $null
        }
    }
    Wait-OnlineAgent $Pool.pool.id $Pool.pool.name "az container logs -g $ResourceGroup -n $ContainerGroupName"
    # Revoke a replaced PAT only now, so the old container could still deregister its agent.
    if ($RotateAciToken -and $exists) { Remove-RegistrationPat $previousPat }
}

function Initialize-Pipeline([string] $Name, [string] $YamlPath) {
    $existing = (Invoke-Ado -Uri "$orgUrl/$projectPath/_apis/pipelines?api-version=7.1").value | Where-Object name -eq $Name
    if ($existing) { return $existing }
    Invoke-Ado -Method POST -Uri "$orgUrl/$projectPath/_apis/pipelines?api-version=7.1" -Body @{
        name          = $Name
        folder        = '\'
        configuration = @{
            type       = 'yaml'
            path       = $YamlPath
            repository = @{ id = $repo.id; name = $repo.name; type = 'azureReposGit' }
        }
    }
}

function Set-QueuePipelinePermission([int] $QueueId, [int] $PipelineId, [bool] $Authorized) {
    Invoke-Ado -Method PATCH -Uri "$orgUrl/$projectPath/_apis/pipelines/pipelinePermissions/queue/$QueueId`?api-version=7.1-preview.1" -Body @{
        pipelines = @(@{ id = $PipelineId; authorized = $Authorized })
    } | Out-Null
}

function Wait-ProjectQueue([string] $Name) {
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $queue = Get-AdoQueue $orgUrl $projectPath $Name
        if (-not $queue) { Start-Sleep -Seconds 10 }
    } until ($queue -or (Get-Date) -gt $deadline)
    if (-not $queue) { throw "Pool '$Name' has not appeared in project '$Project'." }
    $queue
}

Write-Step 'Azure access and resource providers'
$account = Invoke-AzCli account show --subscription $SubscriptionId -o json | ConvertFrom-Json
Write-Host "Signed in as $($account.user.name) to $($account.name)"
$namespaces = @('Microsoft.DevOpsInfrastructure', 'Microsoft.DevCenter', 'Microsoft.ContainerInstance', 'Microsoft.ContainerRegistry', 'Microsoft.ManagedIdentity')
if ($deepDive) { $namespaces += 'Microsoft.PolicyInsights' }
foreach ($namespace in $namespaces) {
    $registration = Invoke-AzCli provider show --subscription $SubscriptionId --namespace $namespace --query registrationState -o tsv
    if ($registration -ne 'Registered') {
        Write-Host "Registering $namespace ..."
        Invoke-AzCli provider register --subscription $SubscriptionId --namespace $namespace --wait -o none
    }
}

# Pools that already exist hold their own agents' cores, so only a new pool needs free quota.
$existingPools = @(az resource list --subscription $SubscriptionId --resource-group $ResourceGroup `
        --resource-type Microsoft.DevOpsInfrastructure/pools --query '[].name' -o tsv 2>$null)
$mdpPools = @([pscustomobject]@{ Name = $MdpPoolName; Sku = $MdpSku })
if ($deepDive) { $mdpPools += [pscustomobject]@{ Name = $MdpStatefulPoolName; Sku = $mdpStatefulSku } }
Write-Step "Managed DevOps Pools quota in $Location for $(($mdpPools | ForEach-Object Sku | Select-Object -Unique) -join ', ')"
$usages = Invoke-AzCli rest --method get -o json `
    --url "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.DevOpsInfrastructure/locations/$Location/usages?api-version=2024-04-04-preview" |
    ConvertFrom-Json
foreach ($mdp in $mdpPools) {
    # Standard_D2ads_v5 -> standardDADSv5Family (2 cores); Standard_E2as_v4 -> standardEASv4Family.
    if ($mdp.Sku -match '^Standard_([A-Z]+)(\d+)([a-z]*)_v(\d+)$') {
        $familyName = 'standard' + $Matches[1] + $Matches[3].ToUpperInvariant() + 'v' + $Matches[4] + 'Family'
        $coresPerAgent = [int]$Matches[2]
        $family = $usages.value | Where-Object { $_.name.value -eq $familyName }
        if (-not $family) { Write-Warning "No MDP quota entry for $familyName in $Location. Check the SKU, or request quota."; continue }
        $free = $family.limit - $family.currentValue
        if ($existingPools -contains $mdp.Name) {
            Write-Host "${familyName}: $($family.currentValue) of $($family.limit) cores used, including existing pool $($mdp.Name)"
            continue
        }
        Write-Host "${familyName}: $($family.currentValue) of $($family.limit) cores used ($free free, $coresPerAgent per agent)"
        if ($free -lt $coresPerAgent) { Write-Warning "No free $familyName quota for $($mdp.Name): its jobs will wait. Choose another -MdpSku or request quota." }
        elseif ($mdp.Name -eq $MdpPoolName -and $free -lt 2 * $coresPerAgent) { Write-Warning 'Not enough free cores for 2 concurrent agents.' }
    }
}

Write-Step "Azure DevOps project '$Project'"
$existingProject = (Invoke-Ado -Uri "$orgUrl/_apis/projects?api-version=7.1").value | Where-Object name -eq $Project
if (-not $existingProject) {
    $process = (Invoke-Ado -Uri "$orgUrl/_apis/process/processes?api-version=7.1").value | Where-Object isDefault | Select-Object -First 1
    $operation = Invoke-Ado -Method POST -Uri "$orgUrl/_apis/projects?api-version=7.1" -Body @{
        name         = $Project
        description  = 'Security comparison: Managed DevOps Pools vs a self-hosted agent on Azure Container Instances.'
        visibility   = 'private'
        capabilities = @{
            versioncontrol  = @{ sourceControlType = 'Git' }
            processTemplate = @{ templateTypeId = $process.id }
        }
    }
    do {
        Start-Sleep -Seconds 3
        $status = (Invoke-Ado -Uri $operation.url).status
    } while ($status -in 'notSet', 'queued', 'inProgress')
    if ($status -ne 'succeeded') { throw "Project creation finished with status '$status'." }
}
$projectInfo = Invoke-Ado -Uri "$orgUrl/_apis/projects/$projectPath`?api-version=7.1"
Write-Host "Project ready: $($projectInfo.name)"

Write-Step 'Self-hosted agent pools for the ACI agents'
$aci = Initialize-SelfHostedPool $AciPoolName
$state.aciPoolId = $aci.pool.id
$state.aciQueueId = $aci.queue.id
if ($deepDive) {
    $aciOnce = Initialize-SelfHostedPool $AciOncePoolName
    $state.aciOncePool = $AciOncePoolName
    $state.aciOncePoolId = $aciOnce.pool.id
    $state.aciOnceQueueId = $aciOnce.queue.id
}
Save-DemoState $state

Write-Step "Azure: Dev Center, Managed DevOps Pools, container registry and identities ($ResourceGroup)"
Invoke-AzCli group create --subscription $SubscriptionId --name $ResourceGroup --location $Location --tags demo=mdp-vs-aci-security -o none
$deepDiveFlag = $deepDive.ToString().ToLowerInvariant()
$mainParameters = @(
    "organizationUrl=$orgUrl", "projectName=$Project", "mdpPoolName=$MdpPoolName", "mdpStandbyAgents=$MdpStandbyAgents", "mdpSku=$MdpSku",
    "mdpStatefulPoolName=$MdpStatefulPoolName", "mdpStatefulSku=$mdpStatefulSku", "deployStatefulPool=$deepDiveFlag", "deployWifIdentity=$deepDiveFlag"
)
if ($MdpPoolAlias) { $mainParameters += "mdpPoolAlias=$MdpPoolAlias" }
$outputs = Invoke-AzCli deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
    --name mdp-vs-aci-main --template-file (Join-Path $script:RepoRoot 'infra/main.bicep') `
    --parameters @mainParameters `
    --query properties.outputs -o json | ConvertFrom-Json
$registryName = $outputs.registryName.value
$loginServer = $outputs.registryLoginServer.value
$pullIdentityId = $outputs.pullIdentityId.value
$state.registryName = $registryName
if ($deepDive) {
    $state.mdpStatefulPool = $MdpStatefulPoolName
    $state.wifIdentityName = $outputs.wifIdentityName.value
}
Save-DemoState $state
Write-Host "MDP pool '$($outputs.mdpPoolName.value)' (Azure DevOps name '$mdpAdoPoolName')$(if ($deepDive) { " and '$MdpStatefulPoolName'" }), registry '$registryName' deployed"

Write-Step 'Agent image (Microsoft documented Dockerfile), built with ACR Tasks'
$image = "$loginServer/azp-agent:linux"
$tags = az acr repository show-tags --subscription $SubscriptionId --name $registryName --repository azp-agent -o tsv 2>$null
if ($RebuildImage -or -not ($tags -contains 'linux')) {
    $buildLog = Join-Path ([IO.Path]::GetTempPath()) "acr-build-$([guid]::NewGuid()).log"
    az acr build --subscription $SubscriptionId --registry $registryName --image azp-agent:linux --platform linux/amd64 (Join-Path $script:RepoRoot 'agent') *> $buildLog
    if ($LASTEXITCODE -ne 0) { Get-Content $buildLog -Tail 40; throw 'Image build failed.' }
    Remove-Item $buildLog -Force
}
Write-Host "Image: $image"

Write-Step 'ACI agents: registration PATs and container groups'
Deploy-AciAgent -Key 'aci' -ContainerGroupName 'aci-azp-agent' -Pool $aci -AgentName 'aci-agent-1' -RunOnce $false
if ($deepDive) {
    Deploy-AciAgent -Key 'aciOnce' -ContainerGroupName 'aci-azp-agent-once' -Pool $aciOnce -AgentName 'aci-once-1' -RunOnce $true
}

Write-Step 'Pushing this repository to Azure Repos'
$repo = Invoke-Ado -Uri "$orgUrl/$projectPath/_apis/git/repositories/$projectPath`?api-version=7.1"
$env:GIT_TERMINAL_PROMPT = '0'
$env:GIT_CONFIG_COUNT = '1'
$env:GIT_CONFIG_KEY_0 = 'http.extraheader'
$env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: bearer $script:AdoToken"
try {
    git -C $script:RepoRoot push --quiet "$orgUrl/$projectPath/_git/$projectPath" HEAD:refs/heads/main
    if ($LASTEXITCODE -ne 0) { throw 'git push to Azure Repos failed.' }
} finally {
    Remove-Item Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0, Env:GIT_TERMINAL_PROMPT -ErrorAction SilentlyContinue
}

Write-Step 'Pipelines'
$pipeline = Initialize-Pipeline 'security-probe' '/pipelines/security-probe.yml'
$state.pipelineId = $pipeline.id
Write-Host "security-probe: $($pipeline.id)"
if ($deepDive) {
    $unapproved = Initialize-Pipeline 'unapproved-pipeline' '/pipelines/unapproved.yml'
    $state.unapprovedPipelineId = $unapproved.id
    Write-Host "unapproved-pipeline: $($unapproved.id) (deliberately not authorised on any pool)"
}
Save-DemoState $state

Write-Step 'Authorising only security-probe to use each pool'
$mdpQueue = Wait-ProjectQueue $mdpAdoPoolName
$state.mdpQueueId = $mdpQueue.id
$queues = @($aci.queue, $mdpQueue)
if ($deepDive) {
    $statefulQueue = Wait-ProjectQueue $MdpStatefulPoolName
    $state.mdpStatefulQueueId = $statefulQueue.id
    $queues += $aciOnce.queue, $statefulQueue
}
foreach ($queue in $queues) {
    Set-QueuePipelinePermission $queue.id $pipeline.id $true
    Write-Host "Authorised security-probe on '$($queue.name)'"
}
if ($deepDive) {
    # Keep the access-control scene repeatable: revoke any permission given during a previous demo.
    Set-QueuePipelinePermission $mdpQueue.id $unapproved.id $false
    Write-Host "unapproved-pipeline is not authorised on '$mdpAdoPoolName'"
}
Save-DemoState $state

if ($deepDive) {
    Write-Step "WIF service connection '$WifServiceConnectionName' (no secret; Reader on $ResourceGroup)"
    $endpoint = (Invoke-Ado -Uri "$orgUrl/$projectPath/_apis/serviceendpoint/endpoints?endpointNames=$WifServiceConnectionName&api-version=7.1").value | Select-Object -First 1
    if (-not $endpoint) {
        $clientId = $outputs.wifClientId.value
        $endpoint = Invoke-Ado -Method POST -Uri "$orgUrl/_apis/serviceendpoint/endpoints?api-version=7.1" -Body ([ordered]@{
            data                             = [ordered]@{
                subscriptionId   = $SubscriptionId
                subscriptionName = $account.name
                environment      = 'AzureCloud'
                scopeLevel       = 'Subscription'
                creationMode     = 'Manual'
            }
            name                             = $WifServiceConnectionName
            type                             = 'AzureRM'
            url                              = 'https://management.azure.com/'
            authorization                    = [ordered]@{
                parameters = [ordered]@{ tenantid = $account.tenantId; serviceprincipalid = $clientId }
                scheme     = 'WorkloadIdentityFederation'
            }
            isShared                         = $false
            isReady                          = $true
            description                      = 'Demo: workload identity federation; the identity has Reader on the demo resource group only.'
            serviceEndpointProjectReferences = @([ordered]@{
                    projectReference = [ordered]@{ id = $projectInfo.id; name = $Project }
                    name             = $WifServiceConnectionName
                    description      = 'Demo: WIF deployment from a Managed DevOps Pool'
                })
        })
        Write-Host "Created service connection $($endpoint.id)"
    }
    $state.wifServiceConnectionId = $endpoint.id
    Save-DemoState $state

    $issuer = $endpoint.authorization.parameters.workloadIdentityFederationIssuer
    $subject = $endpoint.authorization.parameters.workloadIdentityFederationSubject
    if (-not $issuer -or -not $subject) { throw 'The service connection returned no WIF issuer or subject.' }
    $existingCredentials = Invoke-AzCli identity federated-credential list --subscription $SubscriptionId --resource-group $ResourceGroup `
        --identity-name $state.wifIdentityName --query '[].subject' -o tsv
    if ($existingCredentials -notcontains $subject) {
        Invoke-AzCli identity federated-credential create --subscription $SubscriptionId --resource-group $ResourceGroup `
            --identity-name $state.wifIdentityName --name "ado-$WifServiceConnectionName" `
            --issuer $issuer --subject $subject --audiences 'api://AzureADTokenExchange' -o none
        Write-Host 'Added the federated credential (issuer and subject from the service connection)'
    }
    Invoke-Ado -Method PATCH -Uri "$orgUrl/$projectPath/_apis/pipelines/pipelinePermissions/endpoint/$($endpoint.id)?api-version=7.1-preview.1" -Body @{
        resource     = @{ type = 'endpoint'; id = $endpoint.id }
        allPipelines = @{ authorized = $false }
        pipelines    = @(@{ id = $pipeline.id; authorized = $true })
    } | Out-Null
    Write-Host 'Only security-probe may use the service connection'

    Write-Step 'Azure Policy baseline for Managed DevOps Pools (audit mode, demo resource group only)'
    $policy = Invoke-AzCli deployment sub create --subscription $SubscriptionId --location $Location --name mdp-demo-policy `
        --template-file (Join-Path $script:RepoRoot 'infra/policy.bicep') --parameters resourceGroupName=$ResourceGroup `
        --query properties.outputs -o json | ConvertFrom-Json
    $state.policyDefinitionNames = @($policy.definitionNames.value)
    Save-DemoState $state
    Invoke-AzCli policy state trigger-scan --subscription $SubscriptionId --resource-group $ResourceGroup --no-wait -o none
    Write-Host "Assigned: $($state.policyDefinitionNames -join ', '). Compliance results appear within about 30 minutes."
}

Write-Step 'Done'
Write-Host "Pipeline:  $orgUrl/$projectPath/_build?definitionId=$($pipeline.id)"
Write-Host "Pools:     $orgUrl/_settings/agentpools"
Write-Host "Next:      ./scripts/run-probe.ps1 -ProofOfImpact$(if ($deepDive) { ' -DeepDive' })   and   ./scripts/demo-links.ps1"
