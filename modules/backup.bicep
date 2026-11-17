// Recovery Services vault protecting the DC and the member server.

param location string
param tags object
param workspaceId string
param vmNames array

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: 'jt-rsv-corp'
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    // Set redundancy on the vault itself (the old backupstorageconfig API is rejected now).
    redundancySettings: {
      standardTierStorageRedundancy: 'LocallyRedundant'
      crossRegionRestore: 'Disabled'
    }
    securitySettings: {
      // LAB ONLY: off so teardown can delete the vault same day.
      // Production keeps soft delete on: attackers go after backups first.
      softDeleteSettings: {
        softDeleteState: 'Disabled'
        softDeleteRetentionPeriodInDays: 14
      }
    }
  }
}

resource vaultDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: vault
  properties: {
    workspaceId: workspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource policy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = {
  parent: vault
  name: 'jt-daily-6pm-7day'
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: 2
    timeZone: 'Eastern Standard Time'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        '2026-01-01T18:00:00Z'
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          '2026-01-01T18:00:00Z'
        ]
        retentionDuration: {
          count: 7
          durationType: 'Days'
        }
      }
    }
  }
}

resource protectedVms 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = [
  for vmName in vmNames: {
    name: '${vault.name}/Azure/iaasvmcontainer;iaasvmcontainerv2;${resourceGroup().name};${vmName}/vm;iaasvmcontainerv2;${resourceGroup().name};${vmName}'
    properties: {
      protectedItemType: 'Microsoft.Compute/virtualMachines'
      policyId: policy.id
      sourceResourceId: resourceId('Microsoft.Compute/virtualMachines', vmName)
    }
  }
]

output vaultName string = vault.name
