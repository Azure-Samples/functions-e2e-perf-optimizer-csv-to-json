targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
@allowed(['australiaeast', 'eastasia', 'eastus', 'eastus2', 'northeurope', 'southcentralus', 'southeastasia', 'swedencentral', 'uksouth', 'westus2', 'eastus2euap'])
@metadata({
  azd: {
    type: 'location'
  }
})
param location string
param skipVnet bool = false
param csvtojsonServiceName string = ''
param csvtojsonUserAssignedIdentityName string = ''
param applicationInsightsName string = ''
param appServicePlanName string = ''
param logAnalyticsName string = ''
param resourceGroupName string = ''
param storageAccountName string = ''
param vNetName string = ''
param disableLocalAuth bool = true

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var functionAppName = !empty(csvtojsonServiceName) ? csvtojsonServiceName : '${abbrs.webSitesFunctions}csvtojson-${resourceToken}'
var deploymentStorageContainerName = 'app-package-${take(functionAppName, 32)}-${take(toLower(uniqueString(functionAppName, resourceToken)), 7)}'

var altResName = '${abbrs.loadtesting}${resourceToken}'
var profileMappingName = guid(toLower(uniqueString(subscription().id, altResName)))
var testProfileId = '${abbrs.loadtestingProfiles}${guid(toLower(uniqueString(subscription().id, altResName)))}'
var loadtestTestId = '${abbrs.loadtestingTests}${guid(toLower(uniqueString(subscription().id, altResName)))}'

// Organize resources in a resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}${environmentName}'
  location: location
  tags: tags
}

// User assigned managed identity to be used by the function app to reach storage and service bus
module csvtojsonUserAssignedIdentity './core/identity/userAssignedIdentity.bicep' = {
  name: 'csvtojsonUserAssignedIdentity'
  scope: rg
  params: {
    location: location
    tags: tags
    identityName: !empty(csvtojsonUserAssignedIdentityName) ? csvtojsonUserAssignedIdentityName : '${abbrs.managedIdentityUserAssignedIdentities}csvtojson-${resourceToken}'
  }
}

// The application backend is a function app
module appServicePlan './core/host/appserviceplan.bicep' = {
  name: 'appserviceplan'
  scope: rg
  params: {
    name: !empty(appServicePlanName) ? appServicePlanName : '${abbrs.webServerFarms}${resourceToken}'
    location: location
    tags: tags
    sku: {
      name: 'FC1'
      tier: 'FlexConsumption'
    }
  }
}

module csvtojson './app/csvtojson.bicep' = {
  name: 'csvtojson'
  scope: rg
  params: {
    name: functionAppName
    location: location
    tags: tags
    applicationInsightsName: monitoring.outputs.applicationInsightsName
    appServicePlanId: appServicePlan.outputs.id
    runtimeName: 'python'
    runtimeVersion: '3.11'
    storageAccountName: storage.outputs.name
    deploymentStorageContainerName: deploymentStorageContainerName
    identityId: csvtojsonUserAssignedIdentity.outputs.identityId
    identityClientId: csvtojsonUserAssignedIdentity.outputs.identityClientId
    appSettings: {
    }
    virtualNetworkSubnetId: skipVnet ? '' : serviceVirtualNetwork.outputs.appSubnetID
  }
}

// Backing storage for Azure functions csvtojson
module storage './core/storage/storage-account.bicep' = {
  name: 'storage'
  scope: rg
  params: {
    name: !empty(storageAccountName) ? storageAccountName : '${abbrs.storageStorageAccounts}${resourceToken}'
    location: location
    tags: tags
    containers: [{name: deploymentStorageContainerName}]
    publicNetworkAccess: skipVnet ? 'Enabled' : 'Disabled'
    networkAcls: skipVnet ? {} : {
      defaultAction: 'Deny'
    }
  }
}

var storageRoleDefinitionId  = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b' //Storage Blob Data Owner role

// Allow access from csvtojson to storage account using a managed identity
module storageRoleAssignmentCSVtoJSON 'app/storage-Access.bicep' = {
  name: 'storageRoleAssignmentcsvtojson'
  scope: rg
  params: {
    storageAccountName: storage.outputs.name
    roleDefinitionID: storageRoleDefinitionId
    principalID: csvtojsonUserAssignedIdentity.outputs.identityPrincipalId
  }
}

// Virtual Network & private endpoint to blob storage
module serviceVirtualNetwork 'app/vnet.bicep' =  if (!skipVnet) {
  name: 'serviceVirtualNetwork'
  scope: rg
  params: {
    location: location
    tags: tags
    vNetName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
  }
}

module storagePrivateEndpoint 'app/storage-PrivateEndpoint.bicep' = if (!skipVnet) {
  name: 'servicePrivateEndpoint'
  scope: rg
  params: {
    location: location
    tags: tags
    virtualNetworkName: !empty(vNetName) ? vNetName : '${abbrs.networkVirtualNetworks}${resourceToken}'
    subnetName: skipVnet ? '' : serviceVirtualNetwork.outputs.peSubnetName
    resourceName: storage.outputs.name
  }
}

// Monitor application with Azure Monitor
module monitoring './core/monitor/monitoring.bicep' = {
  name: 'monitoring'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsName: !empty(logAnalyticsName) ? logAnalyticsName : '${abbrs.operationalInsightsWorkspaces}${resourceToken}'
    applicationInsightsName: !empty(applicationInsightsName) ? applicationInsightsName : '${abbrs.insightsComponents}${resourceToken}'
    disableLocalAuth: disableLocalAuth  
  }
}

var monitoringRoleDefinitionId = '3913510d-42f4-4e42-8a64-420c390055eb' // Monitoring Metrics Publisher role ID

// Allow access from csvtojson to application insights using a managed identity
module appInsightsRoleAssignmentCSVtoJSON './core/monitor/appinsights-access.bicep' = {
  name: 'appInsightsRoleAssignmentcsvtojson'
  scope: rg
  params: {
    appInsightsName: monitoring.outputs.applicationInsightsName
    roleDefinitionID: monitoringRoleDefinitionId
    principalID: csvtojsonUserAssignedIdentity.outputs.identityPrincipalId
  }
}

// Setup Azure load testing Resource
module loadtesting './core/loadtesting/loadtests.bicep' = {
  name: 'loadtesting'
  scope: rg
  params: {
    name: altResName
    tags: tags 
    location: location
  }
}

module loadtestProfileMapping './core/loadtesting/testprofile-mapping.bicep' = {
   name: 'loadtestprofilemapping'
   scope: rg
   params: {
    testProfileMappingName : profileMappingName
    functionAppResourceName:  csvtojson.outputs.SERVICE_API_NAME
    loadTestingResourceName:  loadtesting.outputs.name
    loadTestProfileId: testProfileId
    }
  }

// App outputs
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.applicationInsightsConnectionString
output RESOURCE_GROUP string = rg.name
output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
output SERVICE_API_NAME string = csvtojson.outputs.SERVICE_API_NAME
output AZURE_FUNCTION_NAME string = csvtojson.outputs.SERVICE_API_NAME
output AZURE_FUNCTION_APP_RESOURCE_ID string = csvtojson.outputs.SERVICE_API_RESOURCE_ID
output AZURE_FUNCTION_APP_TRIGGER_NAME string = csvtojson.name
output LOADTEST_DP_URL string = loadtesting.outputs.uri
output LOADTEST_PROFILE_ID string =  testProfileId
output LOADTEST_TEST_ID string = loadtestTestId
output AZURE_LOADTEST_RESOURCE_NAME string = loadtesting.outputs.name
output AZURE_LOADTEST_RESOURCE_ID string = loadtesting.outputs.id
