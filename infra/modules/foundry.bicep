// foundry.bicep — Foundry account (AIServices) + project + model + RBAC.
// The project uses a managed identity; that MI is granted AcrPull on the private
// ACR so it can pull the agent's signed image. At runtime the agent also gets
// its own dedicated Entra identity (created by the platform on deploy).
targetScope = 'resourceGroup'

param namePrefix string
param token string
param location string
param tags object
param acrId string
param acrLoginServer string
param appInsightsConnectionString string
param modelDeploymentName string
param modelName string
param modelVersion string
param deployerPrincipalId string

// Role definition IDs (Azure constants)
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'   // AcrPull
var acrPushRoleId = '8311e382-0749-4cb8-b61a-304f252e45ec'   // AcrPush

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' = {
  name: '${namePrefix}-foundry-${token}'
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: '${namePrefix}foundry${token}'
    publicNetworkAccess: 'Enabled' // PoC only; in prod: Disabled + PE against the VNet
  }
}

resource foundryProject 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' = {
  parent: foundryAccount
  name: '${namePrefix}-proj'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'IP Protection PoC'
    description: 'Hosted agent with signed image in private ACR'
  }
}

// Content policy (RAI). Prompt Shields (jailbreak + indirect prompt injection)
// are ENABLED by default in Microsoft.DefaultV2 — no need to declare them here,
// and in fact they cannot be overridden with those names. The severity-based
// filters (Hate/Sexual/Violence/SelfHarm) ARE overrideable, and we raise them
// to Medium on both Prompt and Completion as a platform backstop.
resource raiPolicy 'Microsoft.CognitiveServices/accounts/raiPolicies@2025-10-01-preview' = {
  parent: foundryAccount
  name: '${namePrefix}-shield'
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Blocking'
    contentFilters: [
      { name: 'Hate',     blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Hate',     blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Sexual',   blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Sexual',   blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
    ]
  }
}

// Model deployment consumed by the agent for reasoning
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = {
  parent: foundryAccount
  name: modelDeploymentName
  sku: {
    name: 'GlobalStandard'
    capacity: 50
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: modelName
      version: modelVersion
    }
    raiPolicyName: raiPolicy.name
  }
}

// The project's MI needs AcrPull to fetch the agent image
resource acrPullForProject 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acrId, foundryProject.id, acrPullRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: foundryProject.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// The CI / developer needs AcrPush to push the signed image
resource acrPushForDeployer 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  name: guid(acrId, deployerPrincipalId, acrPushRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPushRoleId)
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}

output foundryAccountName string = foundryAccount.name
output projectName string = foundryProject.name
output projectEndpoint string = 'https://${foundryAccount.properties.customSubDomainName}.services.ai.azure.com/api/projects/${foundryProject.name}'
output projectManagedIdentityClientId string = foundryProject.identity.principalId
output projectPrincipalId string = foundryProject.identity.principalId
output acrLoginServerOut string = acrLoginServer
output appInsightsConn string = appInsightsConnectionString
