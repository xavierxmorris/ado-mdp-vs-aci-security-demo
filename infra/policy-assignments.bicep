// Assigns the Managed DevOps Pools policy baseline to the demo resource group only.
targetScope = 'resourceGroup'

param definitionIds array
param displayNames array
param names array
param effect string

resource policyAssignments 'Microsoft.Authorization/policyAssignments@2023-04-01' = [for (id, i) in definitionIds: {
  name: names[i]
  properties: {
    displayName: displayNames[i]
    policyDefinitionId: id
    parameters: {
      effect: {
        value: effect
      }
    }
  }
}]
