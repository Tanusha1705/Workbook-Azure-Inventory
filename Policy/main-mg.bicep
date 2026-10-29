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
  'NetworkWatcherRG*'
  '*ASR*'
  '*SiteRecovery*'
  '*spring*'
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
    description: 'Denies public network access across all major PaaS services while exempting Azure first-party managed resource groups and automated platform provisioning.'
    metadata: {
      category: 'Network'
      version: '3.0.0'
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
          'NetworkWatcherRG*'
          '*ASR*'
          '*SiteRecovery*'
          '*spring*'
        ]
      }
    }
    policyRule: loadJsonContent('azurepolicy.rules.json')
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
