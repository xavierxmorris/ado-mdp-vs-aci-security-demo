// Baseline for comparison: Microsoft's documented Docker agent, hosted on Azure Container Instances.
// https://learn.microsoft.com/azure/devops/pipelines/agents/docker
targetScope = 'resourceGroup'

param location string = resourceGroup().location

@description('Azure DevOps organisation URL, for example https://dev.azure.com/contoso.')
param organizationUrl string

@description('Self-hosted agent pool that the container registers into.')
param aciPoolName string = 'aci-selfhosted-demo'

@description('Agent image, for example myregistry.azurecr.io/azp-agent:linux.')
param image string

param registryLoginServer string

@description('User-assigned identity that can pull from the registry.')
param pullIdentityId string

@secure()
@description('Agent registration PAT (Agent Pools: read & manage), passed as an ACI secure environment variable.')
param azpToken string

param agentName string = 'aci-agent-1'

param containerGroupName string = 'aci-azp-agent'

@description('Deep dive: pass --once so the agent exits after one job and ACI restarts the container (Microsoft\'s documented option).')
param runOnce bool = false

param cpuCores int = 1

param memoryInGB int = 2

resource agent 'Microsoft.ContainerInstance/containerGroups@2025-09-01' = {
  name: containerGroupName
  location: location
  tags: {
    demo: 'mdp-vs-aci-security'
  }
  // Used to pull the image. Any identity on the container group is also reachable by code in the container.
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${pullIdentityId}': {}
    }
  }
  properties: {
    osType: 'Linux'
    sku: 'Standard'
    // A persistent agent, restarted if it exits: Microsoft's default docker run pattern.
    restartPolicy: 'Always'
    imageRegistryCredentials: [
      {
        server: registryLoginServer
        identity: pullIdentityId
      }
    ]
    // No ipAddress block, so the container group has no inbound public endpoint.
    containers: [
      {
        name: 'azp-agent'
        properties: {
          image: image
          // The image's entrypoint is ./start.sh; with --once it is passed through to run.sh.
          command: runOnce ? [
            '/azp/start.sh'
            '--once'
          ] : null
          resources: {
            requests: {
              cpu: cpuCores
              memoryInGB: memoryInGB
            }
          }
          environmentVariables: [
            {
              name: 'AZP_URL'
              value: organizationUrl
            }
            {
              name: 'AZP_POOL'
              value: aciPoolName
            }
            {
              name: 'AZP_AGENT_NAME'
              value: agentName
            }
            {
              name: 'AZP_TOKEN'
              secureValue: azpToken
            }
          ]
        }
      }
    ]
  }
}

output containerGroupName string = agent.name
