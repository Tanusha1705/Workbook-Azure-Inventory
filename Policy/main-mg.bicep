targetScope = 'managementGroup'

@description('Policy effect: Deny, Audit, or Disabled')
@allowed([
  'Audit'
  'Deny'
  'Disabled'
])
param effect string = 'Deny'

@description('Resource group name patterns to exempt from denial')
param excludedResourceGroupPatterns array = [
  'MC_*'
  'databricks-rg-*'
  'cloud-shell-storage-*'
  '*synapse*'
  'AzureBackupRG_*'
]

@description('Name of the policy definition')
param policyDefinitionName string = 'enforce-disable-public-network-access'

@description('Name of the policy assignment')
param policyAssignmentName string = 'assign-disable-public-network-access'

// Policy Definition created at Management Group level
resource policyDef 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: policyDefinitionName
  properties: {
    displayName: 'Enforce Private-Only Access (Disable Public Network Access) with Platform Managed RG Bypass'
    policyType: 'Custom'
    mode: 'Indexed'
    description: 'Denies public network access across core PaaS services (Storage, Key Vault, ACR, SQL, Synapse, Cosmos DB) while exempting Azure first-party managed resource groups (Databricks, AKS, Synapse) and automated platform provisioning (Cloud Shell).'
    metadata: {
      category: 'Network'
      version: '2.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        metadata: {
          displayName: 'Policy Effect'
          description: 'Effect of the policy (Deny, Audit, or Disabled).'
        }
        allowedValues: [
          'Audit'
          'Deny'
          'Disabled'
        ]
        defaultValue: 'Deny'
      }
      excludedResourceGroupPatterns: {
        type: 'Array'
        metadata: {
          displayName: 'Excluded Resource Group Name Patterns'
          description: 'List of resource group wildcard patterns to exempt from denial.'
        }
        defaultValue: [
          'MC_*'
          'databricks-rg-*'
          'cloud-shell-storage-*'
          '*synapse*'
          'AzureBackupRG_*'
        ]
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            anyOf: [
              {
                allOf: [
                  {
                    field: 'type'
                    equals: 'Microsoft.Storage/storageAccounts'
                  }
                  {
                    field: 'Microsoft.Storage/storageAccounts/publicNetworkAccess'
                    notEquals: 'Disabled'
                  }
                ]
              }
              {
                allOf: [
                  {
                    field: 'type'
                    equals: 'Microsoft.KeyVault/vaults'
                  }
                  {
                    field: 'Microsoft.KeyVault/vaults/publicNetworkAccess'
                    notEquals: 'Disabled'
                  }
                ]
              }
              {
                allOf: [
                  {
                    field: 'type'
                    equals: 'Microsoft.ContainerRegistry/registries'
                  }
                  {
                    field: 'Microsoft.ContainerRegistry/registries/publicNetworkAccess'
                    notEquals: 'Disabled'
                  }
                ]
              }
              {
                allOf: [
                  {
                    field: 'type'
                    equals: 'Microsoft.Sql/servers'
                  }
                  {
                    field: 'Microsoft.Sql/servers/publicNetworkAccess'
                    notEquals: 'Disabled'
                  }
                ]
              }
              {
                allOf: [
                  {
                    field: 'type'
                    equals: 'Microsoft.Synapse/workspaces'
                  }
                  {
                    field: 'Microsoft.Synapse/workspaces/publicNetworkAccess'
                    notEquals: 'Disabled'
                  }
                ]
              }
              {
                allOf: [
                  {
                    field: 'type'
                    equals: 'Microsoft.DocumentDB/databaseAccounts'
                  }
                  {
                    field: 'Microsoft.DocumentDB/databaseAccounts/publicNetworkAccess'
                    notEquals: 'Disabled'
                  }
                ]
              }
            ]
          }
          {
            value: '[empty(resourceGroup().managedBy)]'
            equals: 'true'
          }
          {
            count: {
              value: '[parameters(\'excludedResourceGroupPatterns\')]'
              name: 'pattern'
              where: {
                value: '[resourceGroup().name]'
                like: '[current(\'pattern\')]'
              }
            }
            equals: 0
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

// Assignment at the same Management Group level
resource policyAssign 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: policyAssignmentName
  properties: {
    displayName: 'Enforce Private-Only Access with Platform Managed RG Bypass Assignment'
    description: 'Assigns policy enforcing private network access while exempting managed resource groups across all subscriptions under this management group.'
    policyDefinitionId: policyDef.id
    parameters: {
      effect: {
        value: effect
      }
      excludedResourceGroupPatterns: {
        value: excludedResourceGroupPatterns
      }
    }
  }
}

