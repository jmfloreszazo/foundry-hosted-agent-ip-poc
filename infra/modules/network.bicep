// network.bicep — VNet + private-endpoint subnet + private DNS zone for ACR
targetScope = 'resourceGroup'

param namePrefix string
param token string
param location string
param tags object

var vnetName = '${namePrefix}-vnet-${token}'

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.20.0.0/16' ]
    }
    subnets: [
      {
        // Subnet for private endpoints (ACR, and optionally Foundry)
        name: 'snet-pe'
        properties: {
          addressPrefix: '10.20.1.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        // Delegatable subnet for agent egress to private resources
        // (internal DBs, on-prem APIs via peering, etc.)
        name: 'snet-agent-egress'
        properties: {
          addressPrefix: '10.20.2.0/24'
        }
      }
    ]
  }
}

// Private DNS zone to resolve ACR via its private endpoint
resource acrDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.azurecr.io'
  location: 'global'
  tags: tags
}

resource acrDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: acrDnsZone
  name: '${vnetName}-acr-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

output vnetId string = vnet.id
output privateEndpointSubnetId string = vnet.properties.subnets[0].id
output agentEgressSubnetId string = vnet.properties.subnets[1].id
output acrDnsZoneId string = acrDnsZone.id
