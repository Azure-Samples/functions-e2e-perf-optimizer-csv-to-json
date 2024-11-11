param loadTestingResourceName string
param functionAppResourceName string
param loadTestProfileId string
param testProfileMappingName string

resource functionApp 'Microsoft.Web/sites@2023-12-01' existing = {
  name: functionAppResourceName
}

resource loadTestResource 'Microsoft.LoadTestService/loadTests@2023-12-01-preview' existing = {
  name: loadTestingResourceName
}

resource testProfileMapping 'Microsoft.LoadTestService/loadTestProfileMappings@2023-12-01-preview' = {
  name: testProfileMappingName
  scope: functionApp
  properties: {
    azureLoadTestingResourceId: loadTestResource.id
    testProfileId: loadTestProfileId
  }
}

output name string = testProfileMapping.name


