// Azure Policy guardrails at resource group scope.
// Definition IDs are resolved by display name in deploy.sh, so nothing here is hardcoded.

param location string
param policyAllowedLocationsId string
param policyNoNicPublicIpId string
param policyAuditVmBackupId string

resource allowedLocations 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'jt-allowed-locations'
  properties: {
    displayName: 'JT Lab: resources may only be created in ${location}'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyAllowedLocationsId)
    parameters: {
      listOfAllowedLocations: {
        value: [
          location
        ]
      }
    }
    nonComplianceMessages: [
      {
        message: 'This lab only allows resources in ${location}.'
      }
    ]
  }
}

resource denyNicPublicIp 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'jt-deny-nic-public-ip'
  properties: {
    displayName: 'JT Lab: VM network interfaces may not have public IPs'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyNoNicPublicIpId)
    nonComplianceMessages: [
      {
        message: 'Public IPs on VMs are blocked. Connect through Azure Bastion.'
      }
    ]
  }
}

resource auditVmBackup 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'jt-audit-vm-backup'
  properties: {
    displayName: 'JT Lab: audit VMs without Azure Backup'
    policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policyAuditVmBackupId)
  }
}
