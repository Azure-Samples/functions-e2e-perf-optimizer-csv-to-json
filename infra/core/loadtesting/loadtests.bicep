param name string
param location string = resourceGroup().location
param tags object = {}

resource loadtests 'Microsoft.LoadTestService/loadTests@2022-12-01' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  
  properties: {
  }
}

output name string = loadtests.name
output uri string = loadtests.properties.dataPlaneURI
