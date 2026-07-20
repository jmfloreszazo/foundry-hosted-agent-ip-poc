using './main.bicep'

param namePrefix = 'ippoc'
// gpt-4.1 was blocked for new deployments before its EOL (2026-10-14).
// Using gpt-5-mini (GA 2025-08-07, EOL 2027-02-06) in swedencentral GlobalStandard.
param modelDeploymentName = 'gpt-5-mini'
param modelName = 'gpt-5-mini'
param modelVersion = '2025-08-07'
// Fill with the objectId of the CI SP or your user (az ad signed-in-user show)
param deployerPrincipalId = ''
