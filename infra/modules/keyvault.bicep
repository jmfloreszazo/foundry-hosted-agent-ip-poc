// keyvault.bicep — stores the system prompt and sensitive rules OUTSIDE the repo.
// The Foundry project's MI gets "Key Vault Secrets User" to read it at runtime.
// The secret VALUE is NOT set here (would leak to git/state); set it out-of-band:
//   az keyvault secret set --vault-name <kv> --name agent-system-prompt --file prompt.txt
targetScope = 'resourceGroup'

param namePrefix string
param token string
param location string
param tags object

@description('principalId of the Foundry project MI that will read the secret.')
param agentPrincipalId string

var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User

resource keyVault 'Microsoft.KeyVault/vaults@2024-04-01-preview' = {
  name: '${namePrefix}kv${token}'
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true            // RBAC, no access policies
    publicNetworkAccess: 'Disabled'          // reachable only via private endpoint / trusted services
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
  }
}

resource secretsReaderForAgent 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, agentPrincipalId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: agentPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultName string = keyVault.name
