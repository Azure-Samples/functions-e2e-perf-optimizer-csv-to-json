<!--
---
name: Azure Functions end-to-end CSV to JSON converter with Performance Optimizer
description: This repository contains an Azure Functions end-to-end sample with an HTTP function that converts CSV to JSON, deployed to Azure Functions Flex Consumption, and highlights the Performance Optimizer feature to help right size the instance size and HTTP concurrency for the app. The sample also uses managed identity and a virtual network to make sure deployment is secure by default.
page_type: sample
products:
- azure-functions
- azure
- entra-id
- azure-load-testing
urlFragment: functions-e2e-perf-optimizer-csv-to-json
languages:
- python
- bicep
- azdeveloper
---
-->

# Azure Functions end-to-end CSV to JSON converter with Performance Optimizer

This repository contains an Azure Functions end-to-end sample with an HTTP function that converts CSV to JSON, deployed to Azure Functions Flex Consumption, and highlights the Performance Optimizer feature to help right size the instance size and HTTP concurrency for the app. The sample also uses managed identity and a virtual network to make sure deployment is secure by default.

## Prerequisites

+ [Python 3.11](https://www.python.org/)
+ [Azure Developer CLI (AZD)](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)

## Deploy to Azure

Run this command to provision the function app, with any required Azure resources, and deploy your code:

```shell
azd up
```

Alternatively, you can opt-out of a VNet being used in the sample. To do so, use `azd env` to configure `SKIP_VNET` to `true` before running `azd up`:

```bash
azd env set SKIP_VNET true
azd up
```

You're prompted to supply these required deployment parameters:

| Parameter | Description |
| ---- | ---- |
| _Environment name_ | An environment that's used to maintain a unique deployment context for your app. You won't be prompted if you created the local project using `azd init`.|
| _Azure subscription_ | Subscription in which your resources are created.|
| _Azure location_ | Azure region in which to create the resource group that contains the new Azure resources. Only regions that currently support the Flex Consumption plan are shown.|

After publish completes successfully, the required Azure Function and Azure Load Testing resources have been created, as well as a Performance Optimizer profile.

## Inspect the solution (optional)

TODO: Fill out

## Test the solution

TODO: Fill out

## Clean up resources

When you no longer need the resources created in this sample, you can use this command to delete the resources from Azure and avoid incurring any further costs:

```shell
azd down
```
