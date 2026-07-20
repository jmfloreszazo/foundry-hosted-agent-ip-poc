// =============================================================================
// main.bicep  —  Infra for a Foundry Hosted Agent with protected IP
// -----------------------------------------------------------------------------
// PoC goal: the agent's logic (IP) is deployed as a container image in a
// private ACR (private endpoint, no public access), runs in the isolated
// Foundry Agent Service sandbox with a dedicated Entra identity, and the
// developer only orchestrates it from VS Code via the Foundry Toolkit / Skill.
//
// Layers (the two indirect-interaction layers we discussed):
//   Layer 1 (dev-time)  -> coding agent over AHP in VS Code (Copilot/Claude)
//   Layer 2 (runtime)   -> Hosted Agent in Foundry, backed by this infra
// =============================================================================

targetScope = 'resourceGroup'

@minLength(3)
@maxLength(20)
@description('Short prefix used to name resources (e.g. "ippoc").')
param namePrefix string = 'ippoc'

@description('Region. Must be a region where Hosted Agents are available.')
param location string = resourceGroup().location

@description('Name of the model deployment the agent will consume.')
param modelDeploymentName string = 'gpt-4.1'

@description('Model from the Foundry catalog to deploy.')
param modelName string = 'gpt-4.1'

@description('Model version.')
param modelVersion string = '2025-04-14'

@description('Object (principalId) of the developer/CI that needs AcrPush and the project role.')
param deployerPrincipalId string = ''

var token = toLower(uniqueString(resourceGroup().id, namePrefix))
var tags = {
  workload: 'foundry-hosted-agent'
  purpose: 'ip-protection-poc'
  owner: 'jmfloreszazo'
}

// ---------------------------------------------------------------------------
// 1) Private network: the surface the image (IP) travels over never leaves Azure
// ---------------------------------------------------------------------------
module network './modules/network.bicep' = {
  name: 'network'
  params: {
    namePrefix: namePrefix
    token: token
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// 2) Private ACR: home of the agent image (the binary = your IP)
//    Premium + publicNetworkAccess Disabled + private endpoint
// ---------------------------------------------------------------------------
module registry './modules/registry.bicep' = {
  name: 'registry'
  params: {
    namePrefix: namePrefix
    token: token
    location: location
    tags: tags
    vnetId: network.outputs.vnetId
    privateEndpointSubnetId: network.outputs.privateEndpointSubnetId
  }
}

// ---------------------------------------------------------------------------
// 3) Observability: Hosted Agent traces (tool calls, delegation, timing)
// ---------------------------------------------------------------------------
module observability './modules/observability.bicep' = {
  name: 'observability'
  params: {
    namePrefix: namePrefix
    token: token
    location: location
    tags: tags
  }
}

// ---------------------------------------------------------------------------
// 4) Foundry (account + project + model). The project is what "pulls" the
//    signed image from the private ACR and creates the agent's Entra identity.
// ---------------------------------------------------------------------------
module foundry './modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    namePrefix: namePrefix
    token: token
    location: location
    tags: tags
    acrId: registry.outputs.acrId
    acrLoginServer: registry.outputs.acrLoginServer
    appInsightsConnectionString: observability.outputs.appInsightsConnectionString
    modelDeploymentName: modelDeploymentName
    modelName: modelName
    modelVersion: modelVersion
    deployerPrincipalId: deployerPrincipalId
  }
}

// ---------------------------------------------------------------------------
// 5) Key Vault: the system prompt and sensitive rules live here, not in the repo.
//    The Foundry project's MI reads it at runtime. The value is set out-of-band.
// ---------------------------------------------------------------------------
module keyvault './modules/keyvault.bicep' = {
  name: 'keyvault'
  params: {
    namePrefix: namePrefix
    token: token
    location: location
    tags: tags
    agentPrincipalId: foundry.outputs.projectPrincipalId
  }
}

// ---------------------------------------------------------------------------
// Outputs: what azd / the Foundry Toolkit need for the rest of the flow
// ---------------------------------------------------------------------------
output ACR_LOGIN_SERVER string = registry.outputs.acrLoginServer
output ACR_NAME string = registry.outputs.acrName
output FOUNDRY_PROJECT_ENDPOINT string = foundry.outputs.projectEndpoint
output FOUNDRY_MODEL_NAME string = modelDeploymentName
output FOUNDRY_PROJECT_NAME string = foundry.outputs.projectName
output AGENT_IDENTITY_CLIENT_ID string = foundry.outputs.projectManagedIdentityClientId
output KEY_VAULT_URI string = keyvault.outputs.keyVaultUri
output SYSTEM_PROMPT_SECRET string = 'agent-system-prompt'
