// =============================================================================
// jontapia-azure-secops-lab — main.bicep
// Author: Jonathan Tapia (github.com/jontapia)
//
// Hybrid identity + security operations lab:
//   hub-spoke network, Azure Bastion (no VM public IPs), Active Directory
//   forest corp.jontapia.lab, delegated Tier 1 help desk, Key Vault, private
//   endpoint storage, Azure Policy guardrails, Azure Backup, and Microsoft
//   Sentinel detections for brute force, lockouts and privileged group changes.
// =============================================================================

targetScope = 'resourceGroup'

param location string = resourceGroup().location
param owner string = 'jontapia'
param adminUsername string = 'jontapia'

@secure()
@minLength(16)
param adminPassword string

@description('Object ID of the person deploying; gets Key Vault Secrets Officer.')
param deployerObjectId string

param alertEmail string
param domainName string = 'corp.jontapia.lab'
param netbiosName string = 'JONTAPIA'
param vmSize string = 'Standard_B1ms'

// Built-in policy definition names, resolved by display name in deploy.sh
param policyAllowedLocationsId string
param policyNoNicPublicIpId string
param policyAuditVmBackupId string

var dcPrivateIp = '10.10.1.4'
var tags = {
  owner: owner
  project: 'azure-secops-lab'
  environment: 'lab'
  managedBy: 'bicep'
}

module governance 'modules/governance.bicep' = {
  name: 'governance'
  params: {
    location: location
    policyAllowedLocationsId: policyAllowedLocationsId
    policyNoNicPublicIpId: policyNoNicPublicIpId
    policyAuditVmBackupId: policyAuditVmBackupId
  }
}

module security 'modules/security.bicep' = {
  name: 'security'
  params: {
    location: location
    tags: tags
    alertEmail: alertEmail
  }
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    location: location
    tags: tags
    dcPrivateIp: dcPrivateIp
  }
  dependsOn: [
    governance
  ]
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    location: location
    tags: tags
    deployerObjectId: deployerObjectId
    adminPassword: adminPassword
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    tags: tags
    privateLinkSubnetId: network.outputs.privateLinkSubnetId
    blobDnsZoneId: network.outputs.blobDnsZoneId
  }
}

module compute 'modules/compute.bicep' = {
  name: 'compute'
  params: {
    location: location
    tags: tags
    identitySubnetId: network.outputs.identitySubnetId
    serversSubnetId: network.outputs.serversSubnetId
    dcPrivateIp: dcPrivateIp
    dcrId: security.outputs.dcrId
    domainName: domainName
    netbiosName: netbiosName
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSize
  }
}

module backup 'modules/backup.bicep' = {
  name: 'backup'
  params: {
    location: location
    tags: tags
    workspaceId: security.outputs.workspaceId
    vmNames: [
      compute.outputs.dcName
      compute.outputs.srvName
    ]
  }
}

output bastion string = network.outputs.bastionName
output domain string = domainName
output domainAdmin string = '${netbiosName}\\${adminUsername}'
output keyVault string = keyVault.outputs.keyVaultName
output storageAccount string = storage.outputs.storageAccountName
output sentinelWorkspace string = security.outputs.workspaceName
output recoveryVault string = backup.outputs.vaultName
