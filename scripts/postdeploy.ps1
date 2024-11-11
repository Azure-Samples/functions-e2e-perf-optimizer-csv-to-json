$tools = @("az")

foreach ($tool in $tools) {
  if (!(Get-Command $tool -ErrorAction SilentlyContinue)) {
    Write-Host "Error: $tool command line tool is not available, check pre-requisites in README.md"
    exit 1
  }
}

# Load Test API Constants
$ApiVersion = '2024-07-01-preview'
$LoadTestingTokenScope = 'https://cnt-prod.loadtesting.azure.com'

# Function App Details
$FunctionAppName = ${env:AZURE_FUNCTION_NAME}
$FunctionAppTriggerName = ${env:AZURE_FUNCTION_APP_TRIGGER_NAME}
$FunctionAppResourceId = ${env:AZURE_FUNCTION_APP_RESOURCE_ID}

# ALT Resource Details
$LoadTestResourceName = ${env:AZURE_LOADTEST_RESOURCE_NAME}
$ResourceGroupName = ${env:RESOURCE_GROUP}
$TestId = ${env:LOADTEST_TEST_ID}
$DataPlaneURL = "https://" + ${env:LOADTEST_DP_URL}.Trim('"')
$TestProfileId = ${env:LOADTEST_PROFILE_ID}
$TestFileName = 'url-test.json'
$FunctionAppComponentType = 'microsoft.web/sites'

# Load Test Configuration
$EngineInstances = 1
$TestDurationInSec = 60
$VirtualUsers = 25
$RampUpTime = 0
$LoadTestDisplayName = "Test_" + (Get-Date).ToString('yyyyMMddHHmmss');
$TestProfileDisplayName = "TestProfile_" + (Get-Date).ToString('yyyyMMddHHmmss');
$TestProfileRunDisplayName = "TestProfileRun_" + (Get-Date).ToString('yyyyMMddHHmmss');
$TestProfileDescription = ''


############################################
# Auxillary Functions for Azure Load Testing
############################################

function Get-FunctionDefaultKey($FunctionAppName, $FunctionAppTriggerName ) {
    $key = az functionapp function keys list -g $ResourceGroupName -n $FunctionAppName --function-name $FunctionAppTriggerName --query default 
    $key = $key.Trim('"')
 
    return $key
}

function Get-UrlTestConfig($FunctionName, $TriggerName, $VirtualUsers, $DurationInSeconds, $RampUpTime) {
  $FunctionTriggerkey = Get-FunctionDefaultKey -FunctionAppName $FunctionName -FunctionAppTriggerName $TriggerName

  $Config = @{
      "version" = "1.0";
      "scenarios" = @{
          "requestGroup1" = @{
              "requests" = @(
                  @{
                      "requestName" = "Request1";
                      "queryParameters" = @();
                      "requestType" = "URL";
                      "endpoint" = "https://$FunctionName.azurewebsites.net/api/$TriggerName";
                      "headers" = @{
                        "x-functions-key" = $FunctionTriggerkey;
                      };
                      "method" = "GET";
                      "body" = $null;
                      "requestBodyFormat" = $null;
                      "responseVariables" = @();
                  }
              );
              "csvDataSetConfigList" = @();
          };
      };
      "testSetup" = @(
          @{
              "virtualUsersPerEngine" = $VirtualUsers;
              "durationInSeconds" = $DurationInSeconds;
              "loadType" = "Linear";
              "scenario" = "requestGroup1";
              "rampUpTimeInSeconds" = $RampUpTime;
          };
      );
  }
     
  return $Config | ConvertTo-Json -Depth 100
}

# Body is assumed to be in a hashtable format
function Call-AzureLoadTesting($URL, $Method, $Body) {
    Log "Calling $Method on $URL"
    $ContentType = 'application/json'
    if ($Method -eq 'PATCH') {
        $ContentType = 'application/merge-patch+json'
    }

    $AccessToken = Get-LoadTestingAccessToken
    if ($Method -ne 'GET') {
        $RequestContent = $Body | ConvertTo-Json -Depth 100
        return Invoke-RestMethod -Uri $URL -Method $Method -Body $RequestContent -Authentication Bearer -Token $AccessToken -ContentType $ContentType
    } else {
        return Invoke-RestMethod -Uri $URL -Method $Method -Authentication Bearer -Token $AccessToken -ContentType $ContentType
    }
}

function Upload-TestFile($URL, $FileContent, $WaitForCompletion = $true) {
    Log "Uploading test file to $URL"
    $AccessToken = Get-LoadTestingAccessToken
    $Content = [System.Text.Encoding]::UTF8.GetBytes($FileContent)
    $ContentType = 'application/octet-stream'
    $Resp = Invoke-RestMethod -Method 'PUT' -Uri $URL -Authentication Bearer -Token $AccessToken -ContentType $ContentType -Body $Content
    Log "Upload Status: $($Resp.validationStatus)"
    $PollCount = 0
    if ($WaitForCompletion) {
        while ($Resp.validationStatus -ne 'VALIDATION_SUCCESS' -and $Resp.validationStatus -ne 'VALIDATION_FAILURE') {
            if ($PollCount -gt 10) {
                Log "Polling count exceeded 10, exiting"
                break
            }

            Start-Sleep -Seconds 10
            $Resp = Invoke-RestMethod -Method GET -Uri $URL -Authentication Bearer -Token $AccessToken
            Log "Current Validation Status: $($Resp.validationStatus), PollCount: $PollCount"
            $PollCount++
        }
    }

    return $Resp
}


function Get-LoadTestingAccessToken() {
  $AccessToken = az account get-access-token --resource $LoadTestingTokenScope --query accessToken
  $AccessToken = $AccessToken.Trim('"')
  return $AccessToken | ConvertTo-SecureString -AsPlainText 
}

function Poll-TestProfileRun($TestProfileRunURL) {
    Log "Polling TestProfileRun at $TestProfileRunURL"
    $AccessToken = Get-LoadTestingAccessToken
    $Resp = Invoke-RestMethod -Method GET -Uri $TestProfileRunURL -Authentication Bearer -Token $AccessToken
    Log "Current Status: $($Resp.status)"
    $PollCount = 0
    while ($Resp.status -ne 'DONE' -and $Resp.status -ne 'FAILED') {
        if ($PollCount -gt 150) {
            Log "Polling count exceeded 150, exiting"
            break
        }

        Start-Sleep -Seconds 20
        $Resp = Invoke-RestMethod -Method GET -Uri $TestProfileRunURL -Authentication Bearer -Token $AccessToken
        Log "Current Status: $($Resp.status), PollCount: $PollCount"
        $PollCount++
    }
}

function Add-AppComponentMetrics($MetricName, $Aggregation) {
    $MetricId = "$FunctionAppResourceId/providers/microsoft.insights/metricdefinitions/$MetricName";
    az load test server-metric add --test-id $TestId --load-test-resource $LoadTestResourceName --resource-group $ResourceGroupName --metric-id $MetricId --metric-name $MetricName --metric-namespace $FunctionAppComponentType --aggregation $Aggregation --app-component-type $FunctionAppComponentType --app-component-id $FunctionAppResourceId
}

function Log($String) {
    Write-Debug $String
}

# Ensure az load extension is installed
az extension add --name load

# Create Load Test
Log "Creating test with testId: $TestId"
if (az load test show --name $LoadTestResourceName --test-id $TestId --resource-group $ResourceGroupName) {
    Write-Host -ForegroundColor Yellow "Test with ID: $TestId already exists"
    az load test update --name $LoadTestResourceName --test-id $TestId --display-name $LoadTestDisplayName --resource-group $ResourceGroupName --engine-instances $EngineInstances
} else {
    Write-Host -ForegroundColor Yellow "Test with ID: $TestId does not exist. Creating a new test"
    az load test create --name $LoadTestResourceName --test-id $TestId  --display-name $LoadTestDisplayName --resource-group $ResourceGroupName --engine-instances $EngineInstances
}
Write-Host -ForegroundColor Green "Successfully created a load test"

Log "Configuring app component and Metrics"
az load test app-component add --test-id $TestId --load-test-resource $LoadTestResourceName --resource-group $ResourceGroupName --app-component-name $FunctionAppName --app-component-type $FunctionAppComponentType --app-component-id $FunctionAppResourceId --app-component-kind "function" 
Add-AppComponentMetrics -MetricName "OnDemandFunctionExecutionCount" -Aggregation "Total"
Add-AppComponentMetrics -MetricName "AlwaysReadyFunctionExecutionCount" -Aggregation "Total"
Add-AppComponentMetrics -MetricName "OnDemandFunctionExecutionUnits" -Aggregation "Average"
Add-AppComponentMetrics -MetricName "AlwaysReadyFunctionExecutionUnits" -Aggregation "Average"
Add-AppComponentMetrics -MetricName "AlwaysReadyUnits" -Aggregation "Average"

# Upload Test Plan
Log "Upload test plan to test with testId: $TestId"
$TestPlan = Get-UrlTestConfig -FunctionName $FunctionAppName -TriggerName $FunctionAppTriggerName -VirtualUsers $VirtualUsers -DurationInSeconds $TestDurationInSec -RampUpTime $RampUpTime
$TestPlanUploadURL = "$DataPlaneURL/tests/$TestId/files/$TestFileName`?api-version=$ApiVersion`&fileType=URL_TEST_CONFIG"
Log $TestPlanUploadURL
$TestPlanUploadResp = Upload-TestFile -URL $TestPlanUploadURL -FileContent $TestPlan
Write-Host -ForegroundColor Green "Successfully uploaded the test plan to the test"

# Create Test Profile
$TestProfileRequest = @{
    "displayName" = $TestProfileDisplayName;
    "description" = $TestProfileDescription;
    "testId" = $TestId;
    "targetResourceId" = $FunctionAppResourceId;
    "targetResourceConfigurations" = @{
        "kind" = "FunctionsFlexConsumption";
        "configurations" = @{
            "config1" = @{
                "instanceMemoryMB" = "2048";
                "httpConcurrency" = 1;
            };
            "config2" = @{
                "instanceMemoryMB" = "2048";
                "httpConcurrency" = 4;
            };
            "config3" = @{
                "instanceMemoryMB" = "2048";
                "httpConcurrency" = 16;
            };
            "config4" = @{
                "instanceMemoryMB" = "4096";
                "httpConcurrency" = 1;
            };
            "config5" = @{
                "instanceMemoryMB" = "4096";
                "httpConcurrency" = 4;
            };
        }
    }
}

$TestProfileResp = Call-AzureLoadTesting -URL "$DataPlaneURL/test-profiles/$TestProfileId`?api-version=$ApiVersion" -Method 'PATCH' -Body $TestProfileRequest
Write-Host -ForegroundColor Green "Successfully created the test profile"

# Not Running Test Profile Run by default

# Create Test Profile Run
# $TestProfileRunRequest = @{
#     "testProfileId" = $TestProfileId;
#     "displayName" = $TestProfileRunDisplayName;
# }

# $TestProfileRunId = New-Guid 
# $testProfileRunUrl = "$DataPlaneURL/test-profile-runs/$TestProfileRunId" + "?api-version=$ApiVersion"

# $TestProfileRunId = (New-Guid).ToString()
# Log "Creating TestProfileRun with ID: $TestProfileRunId"
# $TestProfileRunURL = "$DataPlaneURL/test-profile-runs/$TestProfileRunId`?api-version=$ApiVersion"
# $TestProfileRunResp = Call-AzureLoadTesting -URL $TestProfileRunURL -Method 'PATCH' -Body $TestProfileRunRequest
# Write-Host -ForegroundColor Green "Successfully created the test profile run"

# Poll-TestProfileRun -TestProfileRunURL $TestProfileRunURL