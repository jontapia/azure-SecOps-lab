// Hub-spoke network: Bastion in the hub, workloads + private endpoints in the spoke.
// No VM in this lab has a public IP.

param location string
param tags object
param dcPrivateIp string

var hubPrefix = '10.0.0.0/16'
var bastionSubnetPrefix = '10.0.1.0/26'
var spokePrefix = '10.10.0.0/16'

// --- NSG for workload subnets -------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'jt-nsg-spoke-workloads'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-From-Bastion'
        properties: {
          description: 'RDP only via Azure Bastion in the hub.'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Deny-RDP-From-Anywhere-Else'
        properties: {
          description: 'Blocks lateral RDP between spoke servers; only Bastion may RDP.'
          priority: 110
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Deny-Internet-Inbound'
        properties: {
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

// --- Hub ----------------------------------------------------------------------
resource hub 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'jt-vnet-hub'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubPrefix
      ]
    }
    subnets: [
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
    ]
  }
}

// --- Spoke --------------------------------------------------------------------
resource spoke 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'jt-vnet-spoke-corp'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        spokePrefix
      ]
    }
    // Every VM in the spoke uses the domain controller for DNS;
    // Azure DNS is the fallback while the DC is still being promoted.
    dhcpOptions: {
      dnsServers: [
        dcPrivateIp
        '168.63.129.16'
      ]
    }
    subnets: [
      {
        name: 'snet-identity'
        properties: {
          addressPrefix: '10.10.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'snet-servers'
        properties: {
          addressPrefix: '10.10.2.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
      {
        name: 'snet-privatelink'
        properties: {
          addressPrefix: '10.10.3.0/24'
          privateEndpointNetworkPolicies: 'Enabled'
        }
      }
    ]
  }
}

resource hubToSpoke 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: hub
  name: 'peer-hub-to-spoke-corp'
  properties: {
    remoteVirtualNetwork: {
      id: spoke.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

resource spokeToHub 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-11-01' = {
  parent: spoke
  name: 'peer-spoke-corp-to-hub'
  properties: {
    remoteVirtualNetwork: {
      id: hub.id
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
  }
}

// --- Bastion ------------------------------------------------------------------
resource bastionPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'jt-pip-bastion'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2023-11-01' = {
  name: 'jt-bastion-hub'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'bastion-ipconfig'
        properties: {
          subnet: {
            id: hub.properties.subnets[0].id
          }
          publicIPAddress: {
            id: bastionPip.id
          }
        }
      }
    ]
  }
}

// --- Private DNS for blob private endpoints ------------------------------------
resource blobDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
  tags: tags
}

resource blobDnsLinkSpoke 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: blobDnsZone
  name: 'link-spoke-corp'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: spoke.id
    }
  }
}

output nsgId string = nsg.id
output identitySubnetId string = spoke.properties.subnets[0].id
output serversSubnetId string = spoke.properties.subnets[1].id
output privateLinkSubnetId string = spoke.properties.subnets[2].id
output blobDnsZoneId string = blobDnsZone.id
output bastionName string = bastion.name
