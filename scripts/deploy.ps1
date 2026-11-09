#Requires -Version 7.2
<#
.SYNOPSIS
    Builds the self-hosted agent security demo (ACI, AKS and Managed DevOps Pools) in Azure and Azure DevOps.

.DESCRIPTION
    Safe to re-run: existing resources are reused. Uses the signed-in Azure CLI identity for Azure and,
    through Microsoft Entra tokens, for Azure DevOps. The only PATs created are the registration tokens
    that Microsoft's documented container agent needs on ACI and AKS; those tokens are what the demo examines.

    Needs: Owner (or Contributor + Role Based Access Control Administrator) on the subscription, and
    Project Collection Administrator in the Azure DevOps organisation, which must use the same Entra tenant.

.EXAMPLE
    ./scripts/deploy.ps1 -Organization contoso -SubscriptionId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Organization,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $Project = 'mdp-vs-aci-security',
    [string] $Location = 'australiaeast',
    [string] $ResourceGroup = 'rg-mdp-vs-aci-security',
    [string] $AciPoolName = 'aci-selfhosted-demo',
    [string] $AksPoolName = 'aks-selfhosted-demo',
    [string] $MdpPoolName = 'mdp-security-demo',
    [ValidateRange(0, 2)] [int] $MdpStandbyAgents = 1,
    [ValidateRange(1, 30)] [int] $PatLifetimeDays = 7,
    # Leave out the AKS cluster and agent.
    [switch] $SkipAks,
    # Replace an agent's registration PAT (the old one is revoked).
    [switch] $RotateAciToken,
    [switch] $RotateAksToken,
    [switch] $RebuildImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')

$orgUrl = "https://dev.azure.com/$Organization"
$projectPath = [uri]::EscapeDataString($Project)
$state = Get-DemoState
$state.organization = $Organization
$state.project = $Project
$state.subscriptionId = $SubscriptionId
$state.resourceGroup = $ResourceGroup
$state.aciPool = $AciPoolName
$state.mdpPool = $MdpPoolName
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

function New-RegistrationPat([string] $Purpose) {
    $created = Invoke-Ado -Method POST -Uri "https://vssps.dev.azure.com/$Organization/_apis/tokens/pats?api-version=7.1-preview.1" -Body @{
        displayName = "$Purpose ($Project demo)"
        scope       = 'vso.agentpools_manage'
        validTo     = (Get-Date).ToUniversalTime().AddDays($PatLifetimeDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
        allOrgs     = $false
    }
    if ($created.patTokenError -and $created.patTokenError -ne 'none') { throw "PAT creation failed: $($created.patTokenError)" }
    Write-Host "Created PAT '$Purpose' (Agent Pools: read & manage), valid to $($created.patToken.validTo); value not displayed"
    $created.patToken
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

function Invoke-Kubectl([string] $ClusterName, [string] $Command, [string] $Directory) {
    # Runs kubectl inside the cluster through the Azure API, so no kubeconfig or admin credential is
    # needed locally. Retries while a new Azure RBAC role assignment propagates.
    $fileArgs = if ($Directory) { Get-ChildItem $Directory -File | ForEach-Object { '--file', $_.Name } } else { @() }
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if ($Directory) { Push-Location $Directory }
        try {
            $raw = az aks command invoke --subscription $SubscriptionId --resource-group $ResourceGroup --name $ClusterName --command $Command @fileArgs -o json 2>&1
        } finally {
            if ($Directory) { Pop-Location }
        }
        $result = $null
        try { $result = ($raw | Where-Object { $_ -is [string] }) -join "`n" | ConvertFrom-Json } catch { }
        if ($result -and $result.exitCode -eq 0) { return $result.logs }
        $message = if ($result) { $result.logs } else { "$raw" }
        if ($message -notmatch '(?i)forbidden|unauthorized|does not have access|AuthorizationFailed') {
            throw "kubectl in cluster failed: $message"
        }
        Write-Host "  Waiting for the Kubernetes role assignment to apply (attempt $attempt of 10)..."
        Start-Sleep -Seconds 30
    }
    throw 'kubectl in cluster still not authorised after 10 attempts.'
}

Write-Step 'Azure access and resource providers'
$account = Invoke-AzCli account show --subscription $SubscriptionId -o json | ConvertFrom-Json
Write-Host "Signed in as $($account.user.name) to $($account.name)"
$namespaces = @('Microsoft.DevOpsInfrastructure', 'Microsoft.DevCenter', 'Microsoft.ContainerInstance', 'Microsoft.ContainerRegistry', 'Microsoft.ManagedIdentity')
if (-not $SkipAks) { $namespaces += 'Microsoft.ContainerService', 'Microsoft.Compute' }
foreach ($namespace in $namespaces) {
    $registration = Invoke-AzCli provider show --subscription $SubscriptionId --namespace $namespace --query registrationState -o tsv
    if ($registration -ne 'Registered') {
        Write-Host "Registering $namespace ..."
        Invoke-AzCli provider register --subscription $SubscriptionId --namespace $namespace --wait -o none
    }
}

Write-Step "Managed DevOps Pools quota in $Location"
$usages = Invoke-AzCli rest --method get -o json `
    --url "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.DevOpsInfrastructure/locations/$Location/usages?api-version=2024-04-04-preview" |
    ConvertFrom-Json
$family = $usages.value | Where-Object { $_.name.value -eq 'standardDADSv5Family' }
if ($family) {
    Write-Host "standardDADSv5Family: $($family.currentValue) of $($family.limit) cores used"
    if (($family.limit - $family.currentValue) -lt 4) { Write-Warning 'Fewer than 4 free cores: the pool may not reach 2 concurrent agents.' }
}

Write-Step "Azure DevOps project '$Project'"
$existingProject = (Invoke-Ado -Uri "$orgUrl/_apis/projects?api-version=7.1").value | Where-Object name -eq $Project
if (-not $existingProject) {
    $process = (Invoke-Ado -Uri "$orgUrl/_apis/process/processes?api-version=7.1").value | Where-Object isDefault | Select-Object -First 1
    $operation = Invoke-Ado -Method POST -Uri "$orgUrl/_apis/projects?api-version=7.1" -Body @{
        name         = $Project
        description  = 'Security comparison of self-hosted Azure Pipelines agents: ACI, AKS and Managed DevOps Pools.'
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

Write-Step 'Self-hosted agent pools for the container agents'
$aci = Initialize-SelfHostedPool $AciPoolName
$state.aciPoolId = $aci.pool.id
$state.aciQueueId = $aci.queue.id
if (-not $SkipAks) {
    $aks = Initialize-SelfHostedPool $AksPoolName
    $state.aksPool = $AksPoolName
    $state.aksPoolId = $aks.pool.id
    $state.aksQueueId = $aks.queue.id
}
Save-DemoState $state

Write-Step "Azure: Dev Center, Managed DevOps Pool, container registry and pull identity ($ResourceGroup)"
Invoke-AzCli group create --subscription $SubscriptionId --name $ResourceGroup --location $Location --tags demo=mdp-vs-aci-security -o none
$outputs = Invoke-AzCli deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
    --name mdp-vs-aci-main --template-file (Join-Path $script:RepoRoot 'infra/main.bicep') `
    --parameters organizationUrl=$orgUrl projectName=$Project mdpPoolName=$MdpPoolName mdpStandbyAgents=$MdpStandbyAgents `
    --query properties.outputs -o json | ConvertFrom-Json
$registryName = $outputs.registryName.value
$loginServer = $outputs.registryLoginServer.value
$pullIdentityId = $outputs.pullIdentityId.value
$state.registryName = $registryName
Save-DemoState $state
Write-Host "MDP pool '$($outputs.mdpPoolName.value)' and registry '$registryName' deployed"

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

Write-Step 'ACI agent: registration PAT and container group'
$containerExists = az container show --subscription $SubscriptionId --resource-group $ResourceGroup --name aci-azp-agent --query name -o tsv 2>$null
if ($containerExists -and -not $RotateAciToken) {
    Write-Host 'ACI agent already deployed; keeping its registration PAT. Use -RotateAciToken to replace it.'
} else {
    $previousAciPat = $state['aciPatAuthorizationId']
    $pat = New-RegistrationPat 'aci-agent-registration'
    $state.aciPatAuthorizationId = $pat.authorizationId
    $state.aciPatValidTo = $pat.validTo
    Save-DemoState $state

    # Pass the PAT through a short-lived parameters file, not a command-line argument.
    $parameterFile = Join-Path ([IO.Path]::GetTempPath()) "aci-$([guid]::NewGuid()).parameters.json"
    try {
        @{
            '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
            contentVersion = '1.0.0.0'
            parameters     = @{ azpToken = @{ value = $pat.token } }
        } | ConvertTo-Json -Depth 5 | Set-Content -Path $parameterFile -Encoding utf8
        Invoke-AzCli deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
            --name mdp-vs-aci-agent --template-file (Join-Path $script:RepoRoot 'infra/aci.bicep') `
            --parameters "@$parameterFile" `
            --parameters organizationUrl=$orgUrl aciPoolName=$AciPoolName image=$image registryLoginServer=$loginServer pullIdentityId=$pullIdentityId `
            -o none
    } finally {
        Remove-Item $parameterFile -Force -ErrorAction SilentlyContinue
        $pat = $null
    }
}
Wait-OnlineAgent $aci.pool.id $AciPoolName "az container logs -g $ResourceGroup -n aci-azp-agent"
# Revoke the replaced PAT only now, so the old container could still deregister its agent.
if ($RotateAciToken) { Remove-RegistrationPat $previousAciPat }

if (-not $SkipAks) {
    Write-Step 'AKS cluster: Entra ID with Azure RBAC, no local accounts, AcrPull for the kubelet identity'
    $deployerObjectId = Invoke-AzCli ad signed-in-user show --query id -o tsv
    $aksOutputs = Invoke-AzCli deployment group create --subscription $SubscriptionId --resource-group $ResourceGroup `
        --name mdp-vs-aci-aks --template-file (Join-Path $script:RepoRoot 'infra/aks.bicep') `
        --parameters registryName=$registryName deployerObjectId=$deployerObjectId `
        --query properties.outputs -o json | ConvertFrom-Json
    $clusterName = $aksOutputs.clusterName.value
    $state.aksCluster = $clusterName
    Save-DemoState $state
    Write-Host "Cluster '$clusterName' deployed"

    Write-Step 'AKS agent: registration PAT, Kubernetes secret and Microsoft documented Deployment'
    $existing = Invoke-Kubectl $clusterName 'kubectl get deployment azdevops-deployment --ignore-not-found -o name' $null
    if ($existing -match 'azdevops-deployment' -and -not $RotateAksToken) {
        Write-Host 'AKS agent already deployed; keeping its registration PAT. Use -RotateAksToken to replace it.'
    } else {
        $previousAksPat = $state['aksPatAuthorizationId']
        $pat = New-RegistrationPat 'aks-agent-registration'
        $state.aksPatAuthorizationId = $pat.authorizationId
        $state.aksPatValidTo = $pat.validTo
        Save-DemoState $state

        # The secret matches Microsoft's "kubectl create secret generic azdevops" step. It is written to a
        # short-lived file that is uploaded with the command, so the PAT never appears in a command line.
        $kubeDir = Join-Path ([IO.Path]::GetTempPath()) "aks-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $kubeDir | Out-Null
        try {
            @(
                'apiVersion: v1'
                'kind: Secret'
                'metadata:'
                '  name: azdevops'
                'type: Opaque'
                'stringData:'
                "  AZP_URL: `"$orgUrl`""
                "  AZP_POOL: `"$AksPoolName`""
                "  AZP_TOKEN: `"$($pat.token)`""
            ) | Set-Content -Path (Join-Path $kubeDir 'secret.yaml') -Encoding utf8
            (Get-Content -Raw (Join-Path $script:RepoRoot 'aks/agent-deployment.yaml')).Replace('__IMAGE__', $image) |
                Set-Content -Path (Join-Path $kubeDir 'agent-deployment.yaml') -Encoding utf8 -NoNewline
            $logs = Invoke-Kubectl $clusterName 'kubectl apply -f secret.yaml -f agent-deployment.yaml' $kubeDir
            Write-Host ($logs -join "`n")
            if ($existing -match 'azdevops-deployment') {
                # Pods read the secret only at start-up, so restart them to pick up the new PAT.
                Invoke-Kubectl $clusterName 'kubectl rollout restart deployment/azdevops-deployment' $null | Out-Null
            }
        } finally {
            Remove-Item $kubeDir -Recurse -Force -ErrorAction SilentlyContinue
            $pat = $null
        }
    }
    Wait-OnlineAgent $aks.pool.id $AksPoolName "az aks command invoke -g $ResourceGroup -n $clusterName --command 'kubectl logs deployment/azdevops-deployment'"
    # Revoke the replaced PAT only now, so the old pod could still deregister its agent.
    if ($RotateAksToken) { Remove-RegistrationPat $previousAksPat }
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

Write-Step "Pipeline 'security-probe'"
$pipeline = (Invoke-Ado -Uri "$orgUrl/$projectPath/_apis/pipelines?api-version=7.1").value | Where-Object name -eq 'security-probe'
if (-not $pipeline) {
    $pipeline = Invoke-Ado -Method POST -Uri "$orgUrl/$projectPath/_apis/pipelines?api-version=7.1" -Body @{
        name          = 'security-probe'
        folder        = '\'
        configuration = @{
            type       = 'yaml'
            path       = '/pipelines/security-probe.yml'
            repository = @{ id = $repo.id; name = $repo.name; type = 'azureReposGit' }
        }
    }
}
$state.pipelineId = $pipeline.id
Save-DemoState $state

Write-Step 'Authorising only this pipeline to use each pool'
$deadline = (Get-Date).AddMinutes(5)
do {
    $mdpQueue = Get-AdoQueue $orgUrl $projectPath $MdpPoolName
    if (-not $mdpQueue) { Start-Sleep -Seconds 10 }
} until ($mdpQueue -or (Get-Date) -gt $deadline)
if (-not $mdpQueue) { throw "The MDP pool '$MdpPoolName' has not appeared in project '$Project'." }
$queues = @($aci.queue, $mdpQueue)
if (-not $SkipAks) { $queues += $aks.queue }
foreach ($queue in $queues) {
    Invoke-Ado -Method PATCH -Uri "$orgUrl/$projectPath/_apis/pipelines/pipelinePermissions/queue/$($queue.id)?api-version=7.1-preview.1" -Body @{
        pipelines = @(@{ id = $pipeline.id; authorized = $true })
    } | Out-Null
    Write-Host "Authorised pipeline $($pipeline.id) on queue '$($queue.name)'"
}
$state.mdpQueueId = $mdpQueue.id
Save-DemoState $state

Write-Step 'Done'
Write-Host "Pipeline:  $orgUrl/$projectPath/_build?definitionId=$($pipeline.id)"
Write-Host "Pools:     $orgUrl/_settings/agentpools"
Write-Host 'Next:      ./scripts/run-probe.ps1 -ProofOfImpact'
