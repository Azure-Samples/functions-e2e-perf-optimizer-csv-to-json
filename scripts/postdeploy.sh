commands=("az")

for cmd in "${commands[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: $cmd command is not available, check pre-requisites in README.md"
    exit 1
  fi
done

# Load Test API Constants
ApiVersion='2024-07-01-preview'
LoadTestingTokenScope='https://cnt-prod.loadtesting.azure.com'

# Function App Details
FunctionAppName="${AZURE_FUNCTION_NAME}"
FunctionAppTriggerName="${AZURE_FUNCTION_APP_TRIGGER_NAME}"
FunctionAppResourceId="${AZURE_FUNCTION_APP_RESOURCE_ID}"

# ALT Resource Details
LoadTestResourceName="${AZURE_LOADTEST_RESOURCE_NAME}"
ResourceGroupName="${RESOURCE_GROUP}"
TestId="${LOADTEST_TEST_ID}"
TestProfileId="${LOADTEST_PROFILE_ID}"
TestFileName='url-test.json'

# Load Test Configuration
EngineInstances=1
TestDuration=60
VirtualUsers=25
RampUpTime=0
LoadTestDisplayName="Test_$(date +'%Y%m%d%H%M%S')"
TestProfileDisplayName="TestProfile_$(date +'%Y%m%d%H%M%S')"
TestProfileRunDisplayName="TestProfileRun_$(date +'%Y%m%d%H%M%S')"
TestProfileDescription=''

############################################
# Auxillary Functions for Azure Load Testing
############################################

Get_FunctionDefaultKey() {
  key=$(az functionapp function keys list -g "$ResourceGroupName" -n "$FunctionAppName" --function-name "$FunctionAppTriggerName" --query default)
  key=$(echo "$key" | tr -d '"')
  echo "$key"
}

Get_UrlTestConfig() {
  FunctionTriggerkey=$(Get_FunctionDefaultKey)
  Config=$(cat <<EOF
{
  "version": "1.0",
  "scenarios": {
    "requestGroup1": {
      "requests": [
        {
          "requestName": "Request1",
          "queryParameters": [],
          "requestType": "URL",
          "endpoint": "https://$FunctionAppName.azurewebsites.net/api/$FunctionAppTriggerName",
          "headers": {
            "x-functions-key": "$FunctionTriggerkey"
          },
          "method": "GET",
          "body": null,
          "requestBodyFormat": null,
          "responseVariables": []
        }
      ],
      "csvDataSetConfigList": []
    }
  },
  "testSetup": [
    {
      "virtualUsersPerEngine": $VirtualUsers,
      "durationInSeconds": $TestDuration,
      "loadType": "Linear",
      "scenario": "requestGroup1",
      "rampUpTimeInSeconds": $RampUpTime
    }
  ]
}
EOF
)
}

Call_AzureLoadTesting() {
  URL=$1
  Method=$2
  Body=$3
  echo "Calling $Method on $URL"
  ContentType='application/json'
  if [ "$Method" == 'PATCH' ]; then
    ContentType='application/merge-patch+json'
  fi

  AccessToken=$(Get_LoadTestingAccessToken)
  if [ "$Method" != 'GET' ]; then
    curl -X "$Method" -H "Authorization: Bearer $AccessToken" -H "Content-Type: $ContentType" -d "$Body" "$URL"
  else
    curl -X "$Method" -H "Authorization: Bearer $AccessToken" -H "Content-Type: $ContentType" "$URL"
  fi
}

Upload_TestFile() {
  URL=$1
  FileContent=$2
  WaitForCompletion=${3:-true}
  echo "Uploading test file to $URL"
  AccessToken=$(Get_LoadTestingAccessToken)
  Resp=$(curl -X PUT -H "Authorization: Bearer $AccessToken" -H "Content-Type: application/octet-stream" --data-binary "$FileContent" "$URL")
  echo "Upload Status: $(echo "$Resp" | jq -r '.validationStatus')"
  PollCount=0
  if [ "$WaitForCompletion" == true ]; then
    while [ "$(echo "$Resp" | jq -r '.validationStatus')" != 'VALIDATION_SUCCESS' ] && [ "$(echo "$Resp" | jq -r '.validationStatus')" != 'VALIDATION_FAILURE' ]; do
      if [ $PollCount -gt 10 ]; then
        echo "Polling count exceeded 10, exiting"
        break
      fi
      sleep 10
      Resp=$(curl -X GET -H "Authorization: Bearer $AccessToken" "$URL")
      echo "Current Validation Status: $(echo "$Resp" | jq -r '.validationStatus'), PollCount: $PollCount"
      PollCount=$((PollCount + 1))
    done
  fi
  echo "$Resp"
}

Get_LoadTestingAccessToken() {
  AccessToken=$(az account get-access-token --resource "$LoadTestingTokenScope" --query accessToken)
  AccessToken=$(echo "$AccessToken" | tr -d '"')
  echo "$AccessToken"
}

Poll_TestProfileRun() {
  TestProfileRunURL=$1
  echo "Polling TestProfileRun at $TestProfileRunURL"
  AccessToken=$(Get_LoadTestingAccessToken)
  Resp=$(curl -X GET -H "Authorization: Bearer $AccessToken" "$TestProfileRunURL")
  echo "Current Status: $(echo "$Resp" | jq -r '.status')"
  PollCount=0
  while [ "$(echo "$Resp" | jq -r '.status')" != 'DONE' ] && [ "$(echo "$Resp" | jq -r '.validationStatus')" != 'FAILED' ]; do
    if [ $PollCount -gt 150 ]; then
      echo "Polling count exceeded 150, exiting"
      break
    fi
    sleep 20
    Resp=$(curl -X GET -H "Authorization: Bearer $AccessToken" "$TestProfileRunURL")
    echo "Current Status: $(echo "$Resp" | jq -r '.status'), PollCount: $PollCount"
    PollCount=$((PollCount + 1))
  done
}

# Ensure az load extension is installed
az extension add --name load

# Get Dataplane URL for Load Testing Resource
DataPlaneURL=$(az load show -n "$LoadTestResourceName" -g "$ResourceGroupName" --query dataPlaneURI)
DataPlaneURL="https://$(echo "$DataPlaneURL" | tr -d '"')"
echo "DataplaneURL: $DataPlaneURL"

# Create Load Test
echo "Creating test with testId: $TestId"
if az load test show --name "$LoadTestResourceName" --test-id "$TestId" --resource-group "$ResourceGroupName"; then
  echo "Test with ID: $TestId already exists"
  az load test update --name "$LoadTestResourceName" --test-id "$TestId" --display-name "$LoadTestDisplayName" --resource-group "$ResourceGroupName" --engine-instances "$EngineInstances"
else
  echo "Test with ID: $TestId does not exist. Creating a new test"
  az load test create --name "$LoadTestResourceName" --test-id "$TestId" --display-name "$LoadTestDisplayName" --resource-group "$ResourceGroupName" --engine-instances "$EngineInstances"
fi
echo "Successfully created a load test"

# Upload Test Plan
echo "Upload test plan to test with testId: $TestId"
TestPlan=$(Get_UrlTestConfig)
TestPlanUploadURL="$DataPlaneURL/tests/$TestId/files/$TestFileName?api-version=$ApiVersion&fileType=URL_TEST_CONFIG"

TestPlanUploadResp=$(Upload_TestFile "$TestPlanUploadURL" "$TestPlan")
echo "Successfully uploaded the test plan to the test"

# Create Test Profile
TestProfileRequest=$(cat <<EOF
{
  "displayName": "$TestProfileDisplayName",
  "description": "$TestProfileDescription",
  "testId": "$TestId",
  "targetResourceId": "$FunctionAppResourceId",
  "targetResourceConfigurations": {
    "kind": "FunctionsFlexConsumption",
    "configurations": {
      "config1": {
        "instanceMemoryMB": "2048",
        "httpConcurrency": 1
      },
      "config2": {
        "instanceMemoryMB": "2048",
        "httpConcurrency": 4
      },
      "config3": {
        "instanceMemoryMB": "2048",
        "httpConcurrency": 16
      },
      "config4": {
        "instanceMemoryMB": "4096",
        "httpConcurrency": 1
      },
      "config5": {
        "instanceMemoryMB": "4096",
        "httpConcurrency": 4
      }
    }
  }
}
EOF
)
TestProfileResp=$(Call_AzureLoadTesting "$DataPlaneURL/test-profiles/$TestProfileId?api-version=$ApiVersion" 'PATCH' "$TestProfileRequest")
echo "Successfully created the test profile"

# Create Test Profile Run
TestProfileRunRequest=$(cat <<EOF
{
  "testProfileId": "$TestProfileId",
  "displayName": "$TestProfileRunDisplayName"
}
EOF
)
TestProfileRunId=$(uuidgen)
TestProfileRunURL="$DataPlaneURL/test-profile-runs/$TestProfileRunId?api-version=$ApiVersion"
