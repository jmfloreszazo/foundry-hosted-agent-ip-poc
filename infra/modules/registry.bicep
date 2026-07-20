// registry.bicep — Private Premium ACR. Home of the agent image = your IP.
// publicNetworkAccess Disabled + private endpoint => the image is not reachable
// from the Internet. Only the Foundry project (via its MI + AcrPull) and the CI
// (AcrPush) can reach it.
targetScope = 'resourceGroup'

param namePrefix string
param token string
param location string
param tags object
param vnetId string
param privateEndpointSubnetId string

var acrName = replace('${namePrefix}acr${token}', '-', '')

resource acr 'Microsoft.ContainerRegistry/registries@2025-11-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    // Premium is required for private endpoints and for content trust / signing
    name: 'Premium'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    adminUserEnabled: false            // no admin credentials: Entra/RBAC only
    publicNetworkAccess: 'Disabled'    // <- the door to the Internet stays closed
    networkRuleBypassOptions: 'AzureServices'
    zoneRedundancy: 'Disabled'
    policies: {
      // Retention for unsigned / unreferenced artifacts
      retentionPolicy: {
        status: 'enabled'
        days: 15
      }
    }
  }
}

// ACR private endpoint inside the VNet
resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${acrName}-pe'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${acrName}-plsc'
        properties: {
          privateLinkServiceId: acr.id
          groupIds: [ 'registry' ]
        }
      }
    ]
  }
}

// Bind the PE to the private DNS zone (privatelink.azurecr.io)
resource acrPeDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: acrPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'acr-config'
        properties: {
          privateDnsZoneId: resourceId('Microsoft.Network/privateDnsZones', 'privatelink.azurecr.io')
        }
      }
    ]
  }
}

output acrId string = acr.id
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
