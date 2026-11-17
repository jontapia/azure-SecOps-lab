// Two Windows Server 2022 VMs, no public IPs:
//   jt-dc01  — domain controller for corp.jontapia.lab (static IP, NTDS on data disk)
//   jt-srv01 — member/management server with RSAT for the help desk
// Both ship Windows Security events to Sentinel through Azure Monitor Agent.

param location string
param tags object
param identitySubnetId string
param serversSubnetId string
param dcPrivateIp string
param dcrId string
param domainName string
param netbiosName string
param adminUsername string

@secure()
param adminPassword string

@description('B1ms = 1 vCPU / 2 GiB. Two of them use 2 vCPUs, half of a free-trial subscription\'s 4-vCPU cap.')
param vmSize string = 'Standard_B1ms'
param autoShutdownTime string = '1900'

var dcName = 'jt-dc01'
var srvName = 'jt-srv01'
var labRootOu = 'OU=_JT-Lab,DC=${replace(domainName, '.', ',DC=')}'

var imageRef = {
  publisher: 'MicrosoftWindowsServer'
  offer: 'WindowsServer'
  sku: '2022-datacenter-g2'
  version: 'latest'
}

// --- NICs -----------------------------------------------------------------------
resource dcNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${dcName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: dcPrivateIp
          subnet: {
            id: identitySubnetId
          }
        }
      }
    ]
  }
}

resource srvNic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${srvName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: serversSubnetId
          }
        }
      }
    ]
  }
}

// --- Domain controller ----------------------------------------------------------
resource dc 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: dcName
  location: location
  tags: union(tags, { role: 'domain-controller' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'JT-DC01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        timeZone: 'Eastern Standard Time'
      }
    }
    storageProfile: {
      imageReference: imageRef
      osDisk: {
        name: '${dcName}-osdisk'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
      dataDisks: [
        {
          name: '${dcName}-data-ntds'
          lun: 0
          createOption: 'Empty'
          diskSizeGB: 8
          caching: 'None' // required for AD DS database integrity
          deleteOption: 'Delete'
          managedDisk: {
            storageAccountType: 'StandardSSD_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: dcNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// --- Member / management server -------------------------------------------------
resource srv 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: srvName
  location: location
  tags: union(tags, { role: 'management-server' })
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'JT-SRV01'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        timeZone: 'Eastern Standard Time'
      }
    }
    storageProfile: {
      imageReference: imageRef
      osDisk: {
        name: '${srvName}-osdisk'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: srvNic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

// --- Build the domain -----------------------------------------------------------
resource dcPromote 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: dc
  name: 'jt-dc-promote'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/dc-promote.ps1')
    }
    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'NetbiosName'
        value: netbiosName
      }
    ]
    protectedParameters: [
      {
        name: 'SafeModePassword'
        value: adminPassword
      }
    ]
    timeoutInSeconds: 3600
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
  }
}

resource srvJoin 'Microsoft.Compute/virtualMachines/runCommands@2024-03-01' = {
  parent: srv
  name: 'jt-member-join'
  location: location
  properties: {
    source: {
      script: loadTextContent('../scripts/member-join.ps1')
    }
    parameters: [
      {
        name: 'DomainName'
        value: domainName
      }
      {
        name: 'NetbiosName'
        value: netbiosName
      }
      {
        name: 'DcIp'
        value: dcPrivateIp
      }
      {
        name: 'OuPath'
        value: 'OU=Servers,${labRootOu}'
      }
      {
        name: 'JoinUser'
        value: adminUsername
      }
    ]
    protectedParameters: [
      {
        name: 'JoinPassword'
        value: adminPassword
      }
    ]
    timeoutInSeconds: 3600
    asyncExecution: false
    treatFailureAsDeploymentFailure: true
  }
  dependsOn: [
    dcPromote
  ]
}

// --- Auto-shutdown (cost control) -------------------------------------------------
resource dcShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${dcName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: 'Eastern Standard Time'
    targetResourceId: dc.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

resource srvShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${srvName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: 'Eastern Standard Time'
    targetResourceId: srv.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

// --- Azure Monitor Agent + Sentinel data collection --------------------------------
resource dcAma 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: dc
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [
    srvJoin // wait until the DC has finished promoting and rebooting
  ]
}

resource srvAma 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: srv
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
  dependsOn: [
    srvJoin
  ]
}

resource dcDcr 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'jt-dcra-security'
  scope: dc
  properties: {
    dataCollectionRuleId: dcrId
  }
  dependsOn: [
    dcAma
  ]
}

resource srvDcr 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'jt-dcra-security'
  scope: srv
  properties: {
    dataCollectionRuleId: dcrId
  }
  dependsOn: [
    srvAma
  ]
}

output dcName string = dc.name
output srvName string = srv.name
output dcId string = dc.id
output srvId string = srv.id
