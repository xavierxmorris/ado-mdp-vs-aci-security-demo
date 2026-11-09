// Deep dive: an Azure Policy baseline for Managed DevOps Pools, assigned in audit mode to the demo resource group.
// Microsoft.DevOpsInfrastructure publishes policy aliases for agent state and networking.
targetScope = 'subscription'

param resourceGroupName string

@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param effect string = 'Audit'

var definitions = [
  {
    name: 'mdp-demo-fresh-agents'
    displayName: 'Managed DevOps Pools should give every job a fresh agent'
    description: 'Flags pools whose agent state isn\'t Stateless ("Fresh agent every time"). Reused agents let one job leave files for the next.'
    condition: {
      field: 'Microsoft.DevOpsInfrastructure/pools/agentProfile.kind'
      notEquals: 'Stateless'
    }
  }
  {
    name: 'mdp-demo-private-network'
    displayName: 'Managed DevOps Pools should run in your own virtual network'
    description: 'Flags pools without VNet injection (fabricProfile.networkProfile.subnetId).'
    condition: {
      field: 'Microsoft.DevOpsInfrastructure/pools/fabricProfile.Vmss.networkProfile.subnetId'
      exists: 'false'
    }
  }
]

resource policyDefinitions 'Microsoft.Authorization/policyDefinitions@2023-04-01' = [for definition in definitions: {
  name: definition.name
  properties: {
    displayName: definition.displayName
    description: definition.description
    policyType: 'Custom'
    mode: 'All'
    metadata: {
      category: 'Azure DevOps'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Audit'
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.DevOpsInfrastructure/pools'
          }
          definition.condition
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}]

module assignments 'policy-assignments.bicep' = {
  name: 'mdp-demo-policy-assignments'
  scope: resourceGroup(resourceGroupName)
  params: {
    definitionIds: [for (definition, i) in definitions: policyDefinitions[i].id]
    displayNames: [for definition in definitions: definition.displayName]
    names: [for definition in definitions: definition.name]
    effect: effect
  }
}

output definitionNames array = [for definition in definitions: definition.name]
