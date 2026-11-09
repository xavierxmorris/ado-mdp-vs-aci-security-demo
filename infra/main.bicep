// Shared infrastructure for the MDP vs ACI security demo.
//   - Dev Center + Dev Center project (required by Managed DevOps Pools)
//   - Managed DevOps Pool: fresh (stateless) agents on a Microsoft-maintained image
//   - Azure Container Registry + user-assigned identity for the ACI agent image
targetScope = 'resourceGroup'

@description('Azure region. Managed DevOps Pools runs in Australia East and Australia Southeast, not Australia Central.')
param location string = resourceGroup().location

@description('Azure DevOps organisation URL, for example https://dev.azure.com/contoso.')
param organizationUrl string

@description('The only Azure DevOps project that can use the MDP pool.')
param projectName string

@description('MDP pool name. Must be globally unique in Azure. MDP creates an Azure DevOps agent pool with this name unless mdpPoolAlias is set.')
param mdpPoolName string = 'mdp-security-demo'

@description('Optional Azure DevOps agent pool name (pool alias, API 2025-09-20 or later). Lets a second deployment keep the same Azure DevOps pool name, and so the same pipeline defaults, under a different, globally unique Azure name.')
param mdpPoolAlias string = ''

@description('Agent VM size. The default MDP quota (5 cores per family) allows two Standard_D2ads_v5 agents.')
param mdpSku string = 'Standard_D2ads_v5'

@description('Maximum MDP agents at any time.')
@minValue(1)
param mdpMaximumConcurrency int = 2

@description('Standby agents kept ready 08:00-18:00 on weekdays (Sydney time). Set to 0 to pay only while jobs run.')
@minValue(0)
param mdpStandbyAgents int = 1

@description('Suffix that makes registry and Dev Center names unique.')
param suffix string = substring(uniqueString(resourceGroup().id), 0, 8)

@description('Deep dive: a second MDP pool configured to reuse agents ("Same agent can be reused by multiple builds").')
param deployStatefulPool bool = true

param mdpStatefulPoolName string = 'mdp-stateful-demo'

@description('Uses a different VM family from the main pool, so the two pools draw on separate MDP quota.')
param mdpStatefulSku string = 'Standard_E2as_v4'

@description('Deep dive: a user-assigned identity for a workload identity federation (WIF) service connection, with Reader on this resource group only.')
param deployWifIdentity bool = true

var tags = {
  demo: 'mdp-vs-aci-security'
}

resource devCenter 'Microsoft.DevCenter/devcenters@2025-02-01' = {
  name: 'dc-mdpaci-${suffix}'
  location: location
  tags: tags
}

resource devCenterProject 'Microsoft.DevCenter/projects@2025-02-01' = {
  name: 'dcp-mdpaci-${suffix}'
  location: location
  tags: tags
  properties: {
    devCenterId: devCenter.id
  }
}

// Seven entries, Sunday first. A count persists until the next entry, so Friday's 18:00 zero covers the weekend.
var weekday = {
  '08:00:00': mdpStandbyAgents
  '18:00:00': 0
}

var statelessAgent = {
  kind: 'Stateless'
}

var statelessAgentWithStandby = {
  kind: 'Stateless'
  resourcePredictionsProfile: {
    kind: 'Manual'
  }
  resourcePredictions: {
    timeZone: 'AUS Eastern Standard Time'
    daysData: [
      {}
      weekday
      weekday
      weekday
      weekday
      weekday
      {}
    ]
  }
}

resource mdpPool 'Microsoft.DevOpsInfrastructure/pools@2025-09-20' = {
  name: mdpPoolName
  location: location
  tags: tags
  properties: {
    devCenterProjectResourceId: devCenterProject.id
    maximumConcurrency: mdpMaximumConcurrency
    organizationProfile: union({
      kind: 'AzureDevOps'
      organizations: [
        {
          url: organizationUrl
          projects: [
            projectName
          ]
          // Pipelines must be explicitly authorised to use the pool.
          openAccess: false
        }
      ]
      // Only the identity that creates the pool administers it in Azure DevOps.
      permissionProfile: {
        kind: 'CreatorOnly'
      }
    }, empty(mdpPoolAlias) ? {} : {
      alias: mdpPoolAlias
    })
    // Stateless = a fresh agent for every job; the VM is discarded afterwards.
    agentProfile: mdpStandbyAgents > 0 ? statelessAgentWithStandby : statelessAgent
    fabricProfile: {
      kind: 'Vmss'
      sku: {
        name: mdpSku
      }
      images: [
        {
          // Microsoft-maintained Azure Pipelines image (Generation 2).
          wellKnownImageName: 'ubuntu-24.04-g2'
        }
      ]
    }
  }
}

// Deep dive: the same pool, misconfigured to reuse agents. Expect residue between jobs.
resource mdpStatefulPool 'Microsoft.DevOpsInfrastructure/pools@2025-09-20' = if (deployStatefulPool) {
  name: mdpStatefulPoolName
  location: location
  tags: tags
  properties: {
    devCenterProjectResourceId: devCenterProject.id
    maximumConcurrency: 1
    organizationProfile: {
      kind: 'AzureDevOps'
      organizations: [
        {
          url: organizationUrl
          projects: [
            projectName
          ]
          openAccess: false
        }
      ]
      permissionProfile: {
        kind: 'CreatorOnly'
      }
    }
    // "Same agent can be reused by multiple builds": the machine waits 30 minutes for the next job.
    agentProfile: {
      kind: 'Stateful'
      maxAgentLifetime: '1.00:00:00'
      gracePeriodTimeSpan: '00:30:00'
    }
    fabricProfile: {
      kind: 'Vmss'
      sku: {
        name: mdpStatefulSku
      }
      images: [
        {
          wellKnownImageName: 'ubuntu-24.04-g2'
        }
      ]
    }
  }
}

resource wifIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (deployWifIdentity) {
  name: 'id-wif-deployer-${suffix}'
  location: location
  tags: tags
}

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'

resource wifReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployWifIdentity) {
  name: guid(resourceGroup().id, 'id-wif-deployer-${suffix}', readerRoleId)
  properties: {
    principalId: wifIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
  }
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: 'acrmdpaci${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource pullIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-aci-acrpull-${suffix}'
  location: location
  tags: tags
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, pullIdentity.id, acrPullRoleId)
  properties: {
    principalId: pullIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

output mdpPoolName string = mdpPool.name
output registryName string = registry.name
output registryLoginServer string = registry.properties.loginServer
output pullIdentityId string = pullIdentity.id
output wifIdentityName string = deployWifIdentity ? wifIdentity!.name : ''
output wifClientId string = deployWifIdentity ? wifIdentity!.properties.clientId : ''
