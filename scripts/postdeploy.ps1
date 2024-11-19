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
$LoadTestResourceId = ${env:AZURE_LOADTEST_RESOURCE_ID}
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

# Function to run az cli command and handle errors
function Run-AzCliCommand {
    param (
        [string]$Command,
        [switch]$SuppressOutput
    )
    try {
        if ($SuppressOutput) {
            # Run the az cli command and redirect output to $null
            Invoke-Expression "$Command > \$null 2>&1"
        } else {
            # Run the az cli command normally
            Invoke-Expression $Command
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code $LASTEXITCODE"
        }
    }
    catch {
        Write-Host "Error: Failed to execute command: $Command"
        throw "Stopping script due to error"
    }
}

function Get-FunctionDefaultKey($FunctionAppName, $FunctionAppTriggerName ) {
    try {
        $key = Run-AzCliCommand -Command "az functionapp function keys list -g $ResourceGroupName -n $FunctionAppName --function-name $FunctionAppTriggerName --query default"
        $key = $key.Trim('"') 
        return $key
    }
    catch {
        Write-Host -ForegroundColor Red "Error: Failed to the default function key for the $FunctionAppTriggerName"
        Write-Host $_.Exception.Message 
        exit 1
    }
}

function Get-UrlTestConfig($FunctionName, $TriggerName, $VirtualUsers, $DurationInSeconds, $RampUpTime) {
    $FunctionTriggerkey = Get-FunctionDefaultKey -FunctionAppName $FunctionName -FunctionAppTriggerName $TriggerName

    $Config = @{
        "version"   = "1.0";
        "scenarios" = @{
            "requestGroup1" = @{
                "requests"             = @(
                    @{
                        "requestName"       = "Request1";
                        "queryParameters"   = @();
                        "requestType"       = "URL";
                        "endpoint"          = "https://$FunctionName.azurewebsites.net/api/$TriggerName";
                        "headers"           = @{
                            "x-functions-key" = $FunctionTriggerkey;
                        };
                        "method"            = "GET";
                        "body"              = $null;
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
                "durationInSeconds"     = $DurationInSeconds;
                "loadType"              = "Linear";
                "scenario"              = "requestGroup1";
                "rampUpTimeInSeconds"   = $RampUpTime;
            };
        );
    }
     
    return $Config | ConvertTo-Json -Depth 100
}

# Body is assumed to be in a hashtable format
function Call-AzureLoadTesting($URL, $Method, $Body) {
    LogDebug "Calling $Method on $URL"
    $ContentType = 'application/json'
    if ($Method -eq 'PATCH') {
        $ContentType = 'application/merge-patch+json'
    }

    $AccessToken = Get-LoadTestingAccessToken
    try {
        if ($Method -ne 'GET') {
            $RequestContent = $Body | ConvertTo-Json -Depth 100
            return Invoke-RestMethod -Uri $URL -Method $Method -Body $RequestContent -Authentication Bearer -Token $AccessToken -ContentType $ContentType
        }
        else {
            return Invoke-RestMethod -Uri $URL -Method $Method -Authentication Bearer -Token $AccessToken -ContentType $ContentType
        }
    }
    catch {
        Write-Host -ForegroundColor Red "Error: Failed to call $Method on $URL"
        Write-Host $_.Exception.Message
        exit 1
    }
}

function Upload-TestFile($URL, $FileContent, $WaitForCompletion = $true) {
    LogDebug "Uploading test file to $URL"
    $AccessToken = Get-LoadTestingAccessToken
    $Content = [System.Text.Encoding]::UTF8.GetBytes($FileContent)
    $ContentType = 'application/octet-stream'
    $Resp = Invoke-RestMethod -Method 'PUT' -Uri $URL -Authentication Bearer -Token $AccessToken -ContentType $ContentType -Body $Content
    LogDebug "Upload Status: $($Resp.validationStatus)"
    $PollCount = 0
    if ($WaitForCompletion) {
        while ($Resp.validationStatus -ne 'VALIDATION_SUCCESS' -and $Resp.validationStatus -ne 'VALIDATION_FAILURE') {
            if ($PollCount -gt 10) {
                Log "Polling count exceeded 10, exiting"
                exit 1
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
 
    try {
        $AccessToken = Run-AzCliCommand -Command "az account get-access-token --resource $LoadTestingTokenScope --query accessToken"
        $AccessToken = $AccessToken.Trim('"')
        return $AccessToken | ConvertTo-SecureString -AsPlainText 
    }
    catch {
        Write-Host -ForegroundColor Red "Error: Failed to get access token for Azure Load Testing"
        Write-Host $_.Exception.Message 
        exit 1
    }
}

function Poll-TestProfileRun($TestProfileRunURL) {
    LogDebug "Polling TestProfileRun at $TestProfileRunURL"
    $AccessToken = Get-LoadTestingAccessToken
    $Resp = Invoke-RestMethod -Method GET -Uri $TestProfileRunURL -Authentication Bearer -Token $AccessToken
    Log "Current Status: $($Resp.status)"
    $PollCount = 0
    while ($Resp.status -ne 'DONE' -and $Resp.status -ne 'FAILED' -and $Resp.status -ne 'STOPPED') {
        if ($PollCount -gt 150) {
            Log "Polling count exceeded 150, exiting"
            exit 1
        }

        Start-Sleep -Seconds 20
        $Resp = Invoke-RestMethod -Method GET -Uri $TestProfileRunURL -Authentication Bearer -Token $AccessToken
        Log "Current Status: $($Resp.status), PollCount: $PollCount"
        $PollCount++
    }
}

function Add-AppComponentMetrics($MetricName, $Aggregation) {
    $MetricId = "$FunctionAppResourceId/providers/microsoft.insights/metricdefinitions/$MetricName";

    try {
        Run-AzCliCommand -Command "az load test server-metric add --test-id $TestId --load-test-resource $LoadTestResourceName --resource-group $ResourceGroupName --metric-id $MetricId --metric-name $MetricName --metric-namespace $FunctionAppComponentType --aggregation $Aggregation --app-component-type $FunctionAppComponentType --app-component-id $FunctionAppResourceId"
    }
    catch {
        Write-Host -ForegroundColor Red "Error: Failed to add server metric $MetricName to the Azure Load testing resource $LoadTestResourceName"
        Write-Host $_.Exception.Message 
        exit 1
    }
}

function UrlEncodeWithCapitalHex {
    param (
        [string]$StringToEncode
    )
    $encodedString = [System.Web.HttpUtility]::UrlEncode($StringToEncode)
    $encodedString = $encodedString -replace '%([0-9a-fA-F]{2})', { "%$($matches[1].ToUpper())" }
    return $encodedString
}

function Create-TestProfile {
    param (
        [string]$TestProfileDisplayName,
        [string]$TestProfileDescription,
        [string]$TestId,
        [string]$FunctionAppResourceId,
        [string]$DataPlaneURL,
        [string]$TestProfileId,
        [string]$ApiVersion
    )

    $TestProfileRequest = @{
        "displayName"                  = $TestProfileDisplayName;
        "description"                  = $TestProfileDescription;
        "testId"                       = $TestId;
        "targetResourceId"             = $FunctionAppResourceId;
        "targetResourceConfigurations" = @{
            "kind"           = "FunctionsFlexConsumption";
            "configurations" = @{
                "config1" = @{
                    "instanceMemoryMB" = "2048";
                    "httpConcurrency"  = 1;
                };
                "config2" = @{
                    "instanceMemoryMB" = "2048";
                    "httpConcurrency"  = 4;
                };
                "config3" = @{
                    "instanceMemoryMB" = "2048";
                    "httpConcurrency"  = 16;
                };
                "config4" = @{
                    "instanceMemoryMB" = "4096";
                    "httpConcurrency"  = 1;
                };
                "config5" = @{
                    "instanceMemoryMB" = "4096";
                    "httpConcurrency"  = 4;
                };
            }
        }
    }

    try {
        $TestProfileResp = Call-AzureLoadTesting -URL "$DataPlaneURL/test-profiles/$TestProfileId`?api-version=$ApiVersion" -Method 'PATCH' -Body $TestProfileRequest
        Write-Host -ForegroundColor Green "Successfully created the test profile"
    }
    catch {
        Write-Host -ForegroundColor Red "Error: Failed to create test profile $TestProfileId"
        Write-Host $_.Exception.Message 
        exit 1
    }
}

function Create-And-Configure-LoadTest {
    param (
        [string]$TestId,
        [string]$LoadTestResourceName,
        [string]$ResourceGroupName,
        [string]$LoadTestDisplayName,
        [int]$EngineInstances,
        [string]$FunctionAppName,
        [string]$FunctionAppTriggerName,
        [string]$FunctionAppComponentType,
        [string]$FunctionAppResourceId,
        [int]$VirtualUsers,
        [int]$TestDurationInSec,
        [int]$RampUpTime,
        [string]$DataPlaneURL,
        [string]$TestFileName,
        [string]$ApiVersion
    )

    Log "Creating test with testId: $TestId"

    try {
        if (az load test show --name $LoadTestResourceName --test-id $TestId --resource-group $ResourceGroupName) {
            Write-Host -ForegroundColor Yellow "Test with ID: $TestId already exists"
            Run-AzCliCommand -Command "az load test update --name $LoadTestResourceName --test-id $TestId --display-name $LoadTestDisplayName --resource-group $ResourceGroupName --engine-instances $EngineInstances"
        } else {
            Write-Host -ForegroundColor Yellow "Test with ID: $TestId does not exist. Creating a new test"
            Run-AzCliCommand -Command "az load test create --name $LoadTestResourceName --test-id $TestId --display-name $LoadTestDisplayName --resource-group $ResourceGroupName --engine-instances $EngineInstances"
        }
        Write-Host -ForegroundColor Green "Successfully created load test $TestId in the Azure Load Testing Resource $LoadTestResourceName"
    } catch {
        Write-Host -ForegroundColor Red "Error: Failed to create or update test $TestId in the Azure Load Testing Resource $LoadTestResourceName"
        Write-Host $_.Exception.Message
        exit 1
    }

    # Upload Test Plan
    Log "Upload test plan to test with testId: $TestId"
    $TestPlan = Get-UrlTestConfig -FunctionName $FunctionAppName -TriggerName $FunctionAppTriggerName -VirtualUsers $VirtualUsers -DurationInSeconds $TestDurationInSec -RampUpTime $RampUpTime
    $TestPlanUploadURL = "$DataPlaneURL/tests/$TestId/files/$TestFileName`?api-version=$ApiVersion`&fileType=URL_TEST_CONFIG"

    try {
        $TestPlanUploadResp = Upload-TestFile -URL $TestPlanUploadURL -FileContent $TestPlan
        Write-Host -ForegroundColor Green "Successfully uploaded the test plan to the test"
    } catch {
        Write-Host -ForegroundColor Red "Error: Failed to upload test plan $TestPlan to the test $TestId in the Azure Load Testing Resource $LoadTestResourceName"
        Write-Host $_.Exception.Message
        exit 1
    }

    # Configure App Components and metrics
    Log "Configuring app component and metrics"

    try {
        Run-AzCliCommand -Command "az load test app-component add --test-id $TestId --load-test-resource $LoadTestResourceName --resource-group $ResourceGroupName --app-component-name $FunctionAppName --app-component-type $FunctionAppComponentType --app-component-id $FunctionAppResourceId --app-component-kind 'function'"
    } catch {
        Write-Host -ForegroundColor Red "Error: Failed to add app component $FunctionAppName to the test $TestId in the Azure Load Testing Resource $LoadTestResourceName"
        Write-Host $_.Exception.Message
        exit 1
    }

    Add-AppComponentMetrics -MetricName "OnDemandFunctionExecutionCount" -Aggregation "Total"
    Add-AppComponentMetrics -MetricName "AlwaysReadyFunctionExecutionCount" -Aggregation "Total"
    Add-AppComponentMetrics -MetricName "OnDemandFunctionExecutionUnits" -Aggregation "Average"
    Add-AppComponentMetrics -MetricName "AlwaysReadyFunctionExecutionUnits" -Aggregation "Average"
    Add-AppComponentMetrics -MetricName "AlwaysReadyUnits" -Aggregation "Average"  
}

function Log($String) {
    Write-Host $String
}

function LogDebug($String) {
    Write-Debug $String
}

# Ensure az load extension is installed
az extension add --name load

# Create and configure test
Create-And-Configure-LoadTest -TestId $TestId -LoadTestResourceName $LoadTestResourceName -ResourceGroupName $ResourceGroupName -LoadTestDisplayName $LoadTestDisplayName -EngineInstances $EngineInstances -FunctionAppName $FunctionAppName -FunctionAppTriggerName $FunctionAppTriggerName -FunctionAppComponentType $FunctionAppComponentType -FunctionAppResourceId $FunctionAppResourceId -VirtualUsers $VirtualUsers -TestDurationInSec $TestDurationInSec -RampUpTime $RampUpTime -DataPlaneURL $DataPlaneURL -TestFileName $TestFileName -ApiVersion $ApiVersion

# Create Test Profile
Create-TestProfile -TestProfileDisplayName $TestProfileDisplayName -TestProfileDescription $TestProfileDescription -TestId $TestId -FunctionAppResourceId $FunctionAppResourceId -DataPlaneURL $DataPlaneURL -TestProfileId $TestProfileId -ApiVersion $ApiVersion

# Not Running Test Profile Run by default

# Create Test Profile Run
$TestProfileRunRequest = @{
    "testProfileId" = $TestProfileId;
    "displayName"   = $TestProfileRunDisplayName;
}

$TestProfileRunId = (New-Guid).ToString().ToLower()
Log "Creating TestProfileRun with ID: $TestProfileRunId"
$TestProfileRunURL = "$DataPlaneURL/test-profile-runs/$TestProfileRunId`?api-version=$ApiVersion"

try {
    $TestProfileRunResp = Call-AzureLoadTesting -URL $TestProfileRunURL -Method 'PATCH' -Body $TestProfileRunRequest
    Write-Host -ForegroundColor Green "Successfully created the test profile run"
}
catch {
    Write-Host -ForegroundColor Red "Error: Failed to create test profile run $TestProfileRunId"
    Write-Host $_.Exception.Message 
    exit 1
}

# $EncodedFunctionResourceId = UrlEncodeWithCapitalHex -StringToEncode "$FunctionAppResourceId"
# $EncodedAltResourceId = UrlEncodeWithCapitalHex -StringToEncode "$LoadTestResourceId"
# $PerfOptimizerURL = "https://portal.azure.com/#view/Microsoft_Azure_CloudNativeTesting/TestProfileRun/resourceId/$EncodedAltResourceId/testProfileId/$TestProfileId/openingFromBlade~/true/sourceResouruceId/$EncodedFunctionResourceId"
# Write-Host -ForegroundColor Green "Performance Optimizer URL - $PerfOptimizerURL"

# Uncomment the following line to poll the test profile run

# Poll-TestProfileRun -TestProfileRunURL $TestProfileRunURL