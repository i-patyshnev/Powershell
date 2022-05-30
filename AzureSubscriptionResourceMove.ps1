#Requires -PSEdition Desktop

Param (
    [string]$Mode
    )

    <#
    .SYNOPSIS
        Script for мalidation and moving resource groups between subscriptions
    .DESCRIPTION
        Enter SubscriptionID and Resource Groups in first section
        Run with key -Mode Move to move resources
        You could confirm or decline export list of resources as json
    .EXAMPLE
        PS C:\> AzureSubscriptionResourceMove.ps1 -Mode Move
    .LINK
        https://github.com/i-patyshnev/Powershell/blob/main/AzureSubscriptionResourceMove.ps1
    #>

# Enter SubscriptionID and Resource Groups here
$SourceSubscriptionID = '<Enter your Source Subscription ID>'
$SourceResourceGroupName = '<Enter your Source Resource Group Name>'
$TargetSubscriptionID = '<Enter your Target Subscription ID>'
$TargetResourceGroupName = '<Enter your Target Resource Group Name>'

# List of excluded resources
$excludedResourceTypes = @('Microsoft.Synapse/workspaces')

function Get-AzureValidateResourceMoveResult
{

    # Preparing the request body
    $requestValid = @{
        Uri = "https://management.azure.com/subscriptions/$sourceSubscriptionID/resourceGroups/$sourceresourceGroupName/validateMoveResources?api-version=2021-04-01"
        Method = 'Post'
        Body = $body
        ContentType = 'application/json'
        Headers = @{Authorization = $token}
    }
 
    try {
        # Sending request for validation
        $return = Invoke-WebRequest  @requestValid -ErrorAction Stop
    }
    catch {
        # Error processing
        $FormattedError1 = $_|ConvertFrom-Json
        Write-host "Error code: "  $FormattedError1.error.code -ForegroundColor Red
        Write-host "Error Message: " $FormattedError1.error.message -ForegroundColor Red
        Write-host "Error details: " -ForegroundColor Red
        $FormattedError1.error.details|Format-List *
        throw "Error occured. Cannot continue."
    }
 
    # Preparing status query
    $resultValid = @{
        Uri = $($return.Headers.Location)
        Method = 'Get'
        ContentType = 'application/json'
        Headers = @{Authorization = $token}
    }
 
    # Waiting for validation results
    do {
        Write-Host 'Waiting for validation result to be ready ...'
        Start-Sleep -Seconds $return.Headers.'Retry-After'
 
        try {
            $statusV = Invoke-WebRequest @resultValid -ErrorAction Stop
        }
        catch {
            # Error processing
            $FormattedError2 = $_.ErrorDetails.Message|ConvertFrom-Json
            Write-host "Error code: "  $FormattedError2.error.code -ForegroundColor Red
            Write-host "Error Message: " $FormattedError2.error.message -ForegroundColor Red
            Write-host "Error details: " -ForegroundColor Red
            $FormattedError2.error.details|Format-List *
            break
        }
    } while($statusV.statusCode -eq 202)

    if($statusV.statusCode -eq 204){
        Write-Host "Validation succeeded" -ForegroundColor Green
        if ($Mode -eq 'Move'){
            Get-AzureResourceMoveResult @ResourcesData
        }
    }
}

function Get-AzureResourceMoveResult
{
    # Preparing the request body
    $requestMove = @{
        Uri = "https://management.azure.com/subscriptions/$sourceSubscriptionID/resourceGroups/$sourceresourceGroupName/moveResources?api-version=2021-04-01"
        Method = 'Post'
        Body = $body
        ContentType = 'application/json'
        Headers = @{Authorization = $token}
    }

    try {
        # Sending request for moving
        $returnM = Invoke-WebRequest  @requestMove -ErrorAction Stop
    }
    catch {
        # Error processing
        $FormattedErrorM1 = $_|ConvertFrom-Json
        Write-host "Error code: "  $FormattedErrorM1.error.code -ForegroundColor Red
        Write-host "Error Message: " $FormattedErrorM1.error.message -ForegroundColor Red
        Write-host "Error details: " -ForegroundColor Red
        $FormattedErrorM1.error.details|Format-List *
        throw "Error occured. Cannot continue."
    }
    # Preparing status query
    $resultMove = @{
        Uri = $($returnM.Headers.Location)
        Method = 'Get'
        ContentType = 'application/json'
        Headers = @{Authorization = $token}
    }

    do {
        Write-Host 'Waiting for resource move result ...'
        Start-Sleep -Seconds $returnM.Headers.'Retry-After'
 
        try {
            $statusM = Invoke-WebRequest @resultMove -ErrorAction Stop
        }
        catch {
            # Error processing
            $FormattedErrorM2 = $_.ErrorDetails.Message|ConvertFrom-Json
            Write-host "Error code: "  $FormattedErrorM2.error.code -ForegroundColor Red
            Write-host "Error Message: " $FormattedErrorM2.error.message -ForegroundColor Red
            Write-host "Error details: " -ForegroundColor Red
            $FormattedErrorM2.error.details|Format-List *
            break
        }
    } while($statusM.statusCode -eq 202)

    if($statusM.statusCode -eq 204){
        Write-Host "Resources moved successfully" -ForegroundColor Green    
    }
}


#region Main
 # Checking for login on Azure
 $currentContext = (Get-AzContext).Subscription.SubscriptionId
 if(!$currentContext) {
     Login-AzAccount -SubscriptionId $sourceSubscriptionID
 }
 if($currentContext -ne $SourceSubscriptionID) {
     Select-AzSubscription -SubscriptionId $SourceSubscriptionID
 }

 # Get access token
 $currentAzureContext = Get-AzContext
 $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
 $profileClient = New-Object Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient($azProfile)
 $token = "Bearer " + $profileClient.AcquireAccessToken($currentAzureContext.Tenant.TenantId).AccessToken

# Filling up array with resources
$resourceIDs = foreach ($resource in (Get-AzResource -ResourceGroupName $SourceResourceGroupName)) {
    $included = $true
    if ($null -ne $resource.ParentResource) {
        # Skip child resources
    }
    else {
        foreach ($excludedResourceType in $excludedResourceTypes) {
            if ($resource.ResourceType -eq $excludedResourceType) {
                # Filtering by exclude list
                write-host "Excluding resource: $($resource.resourceId)" -ForegroundColor Yellow
                $included = $false
            }
        }
        if ($included) {
            $resource.resourceId 
        }
    }
}
if (!$resourceIDs) {
    Write-Warning "No resources to be validated!"
    return
}
elseif ($resourceIDs.GetType().Name -eq 'String') { 
    $resourceIDs = @($resourceIDs)
}

# Asking for export resource list
$ExportAsk = Read-Host "Export list of resources for moving to txt file? [y/n]" 
while($ExportAsk -ne "y")
{
    if ($ExportAsk -eq 'n') {break}
    $ExportAsk = Read-Host "Export list of resources for moving to txt file? [y/n]" -ForegroundColor Green
}

if ($ExportAsk -eq 'y') {
    $ExportRes = $resourceIDs | ConvertTo-Json
    $ExportRes | Out-File Resources.txt
    Write-Host 'Exported to Resources.txt' -ForegroundColor Green
}

# Forming request body
$body = @{
    resources=$resourceIDs ;
    TargetResourceGroup = "/subscriptions/$targetSubscriptionID/resourceGroups/$targetresourceGroupName"
} | ConvertTo-Json

$ResourcesData = @{
    SourceSubscriptionID = $SourceSubscriptionID
    SourceResourceGroupName = $SourceResourceGroupName
    TargetSubscriptionID = $TargetSubscriptionID
    TargetResourceGroupName = $TargetResourceGroupName
    ExcludedResourceTypes = $excludedResourceTypes
    Token = $token
}

Get-AzureValidateResourceMoveResult @ResourcesData
#endregion Main
