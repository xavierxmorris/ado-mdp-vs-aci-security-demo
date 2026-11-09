// Second baseline: Microsoft's documented Kubernetes deployment of the same container agent, on AKS.
// https://learn.microsoft.com/azure/devops/pipelines/agents/docker#use-azure-kubernetes-service-cluster
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Existing registry with the agent image. AKS gets AcrPull, as "az aks update --attach-acr" would grant.')
param registryName string

@description('Object ID of the deploying user. It gets Azure Kubernetes Service RBAC Cluster Admin to apply manifests.')
param deployerObjectId string

param nodeVmSize string = 'Standard_D2ads_v5'

param suffix string = substring(uniqueString(resourceGroup().id), 0, 8)

var tags = {
  demo: 'mdp-vs-aci-security'
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: registryName
}

// Entra ID sign-in with Azure RBAC and no local accounts; otherwise AKS defaults (no network policy).
resource cluster 'Microsoft.ContainerService/managedClusters@2025-07-01' = {
  name: 'aks-mdpaci-${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: 'aks-mdpaci-${suffix}'
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: 1
        vmSize: nodeVmSize
        osType: 'Linux'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
    }
  }
}

var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var aksRbacClusterAdminRoleId = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'

resource kubeletAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registry
  name: guid(registry.id, cluster.id, acrPullRoleId)
  properties: {
    principalId: cluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
  }
}

resource deployerClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: cluster
  name: guid(cluster.id, deployerObjectId, aksRbacClusterAdminRoleId)
  properties: {
    principalId: deployerObjectId
    principalType: 'User'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksRbacClusterAdminRoleId)
  }
}

output clusterName string = cluster.name
