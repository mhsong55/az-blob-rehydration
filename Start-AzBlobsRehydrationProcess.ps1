
function Install-RequiredModules {
  param (
    [Parameter(Mandatory = $true)] [string[]] $RequiredModules
  )
  try {
    foreach ($module in $RequiredModules) {
      if (-not (Get-Module -Name $module)) {
        if (Get-Module -ListAvailable -Name $module) {
          Write-Host "Importing module $module ..."
          Import-Module -Name $module -ErrorAction Stop
        } else {
          Write-Host "Required module $module is not installed. Installing..."
          Install-Module -Name $module -Scope CurrentUser -ErrorAction Stop
        }
      }
    }
    Write-Host "Finished processing module: $module."
  } catch {
    $errorMessage = $_.Exception.Message
    $errorType = $_.Exception.GetType().Name
    $errorLine = $_.InvocationInfo.ScriptLineNumber
    $errorPos = $_.InvocationInfo.PositionMessage

    Write-Host "$errorType - $errorMessage at line $errorLine"
    Write-Host "Detail:`n$errorPos"
    Write-Host "Stack Trace:`n$($_.Exception.StackTrace)"
    throw
  }
}

function Write-ErrorLog {
  param (
    [Parameter(Mandatory = $true)] [PSObject] $Error
  )
  $errorMessage = $Error.Exception.Message
  $errorType = $Error.Exception.GetType().Name
  $errorLine = $Error.InvocationInfo.ScriptLineNumber
  $errorPos = $Error.InvocationInfo.PositionMessage

  Write-Log -Level ERROR -Message "$errorType - $errorMessage at line $errorLine"
  Write-Log -Level DEBUG -Message "Detail:`n$errorPos"
  Write-Log -Level DEBUG -Message "Stack Trace:`n$($Error.Exception.StackTrace)"
}

function Get-TimeNow {
  $time = "" | Select-Object DateTime, TimeToSeconds
  $time.DateTime = Get-Date
  $time.TimeToSeconds = $time.DateTime.Hour * 3600 + $time.DateTime.Minute * 60 + $time.DateTime.Second
  return $time
}

function Confirm-AzCliLogin {
  param (
    [Parameter(Mandatory = $true)] [string] $TenantId,
    [Parameter(Mandatory = $true)] [string] $SubscriptionId
  )
  try {
    $loginStatus = az account show 2>$null

    if (-not $loginStatus) {
      Write-Log -Level INFO -Message "User is not logged in to Azure. Proceeding login..."
      az login --tenant $TenantId
    } else {
      $loginStatus = $loginStatus | ConvertFrom-Json
      if ($loginStatus.tenantId -ne $TenantId) {
        Write-Log -Level INFO -Message "User is logged in to Azure, but the tenant is not matched. Changing tenant..."
        az login --tenant $TenantId
      } elseif ($loginStatus.id -ne $SubscriptionId) {
        Write-Log -Level INFO -Message "User is logged in to Azure, but the subscription is not matched. Changing subscription..."
        az account set --subscription $SubscriptionId
        $loginStatus = az account show 2>$null
        if ($loginStatus.id -ne $SubscriptionId) {
          Write-Log -Level ERROR -Message "Subscription change failed. Subscription is not matched."
          exit 1
        }
      }
    }
    Write-Log -Level INFO -Message "Azure login status check completed"
  } catch {
    Write-ErrorLog -Error $_
    throw
  }
}

function ConvertFrom-DateTimeToFormattedString {
  param (
    [Parameter(Mandatory = $true)] [datetime] $DateTime
  )
  $offset = ([regex]::Match((Get-TimeZone).DisplayName, '([+-]\d{2}:\d{2})')).Groups[1].Value
  return $DateTime.ToString("yyyy-MM-dd HH:mm:ss$offset")
}

function Get-DateTimeFromString {
  param (
    [Parameter(Mandatory = $true)] [string] $DateTimeString
  )
  try {
    $dateTime = [datetime]::Parse($DateTimeString)
    return $dateTime
  } catch {
    Write-ErrorLog -Error $_
    throw
  }
}

function Get-AzBlobListByTier {
  param (
    [Parameter(Mandatory = $true)] [string] $StorageAccountName,
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $ContainerName,
    [Parameter(Mandatory = $true)] [string] $TierFilter,
    [Parameter(Mandatory = $true)] [string] $StorageAccountKey,
    [string] $OutputFormat,
    [datetime] $StartDate,
    [datetime] $EndDate
  )
  try {
    $hasOutputFormat = $PSBoundParameters.ContainsKey('OutputFormat')
    switch ($hasOutputFormat) {
      $true { 
        $outputFormat = ".$OutputFormat"
      }
      $false {
        Write-Log -Level INFO -Message "OutputFormat is not provided. Using default format."
        $outputFormat = ""
      }
    }
    
    $blobs = az storage blob list `
      --account-name $StorageAccountName `
      --container-name $ContainerName `
      --account-key $StorageAccountKey `
      --query "[?properties.blobTier=='$TierFilter']$outputFormat" 
      | ConvertFrom-Json -Depth 5

    $filteredBlobs = New-Object System.Collections.ArrayList
    foreach ($blob in $blobs) {
      if ($hasOutputFormat) {
        $lastModified = [datetime]::Parse($blob.LastModified)
      } else {
        $lastModified = [datetime]::Parse($blob.properties.lastModified)
      }
      if ($lastModified -ge $StartDate -and $lastModified -le $EndDate) {
        Write-Log -Level DEBUG -Message "Blob : $($blob.Name), lastModified : $(ConvertFrom-DateTimeToFormattedString -DateTime $lastModified), StartDate : $(ConvertFrom-DateTimeToFormattedString -DateTime $StartDate), EndDate : $(ConvertFrom-DateTimeToFormattedString -DateTime $EndDate)"
        [void]$filteredBlobs.Add($blob)
      }
    }

    if ($filteredBlobs.Count -eq 0) {
      Write-Log -Level INFO -Message "No $TierFilter Tier blobs found in the search period ($(ConvertFrom-DateTimeToFormattedString -DateTime $StartDate) ~ $(ConvertFrom-DateTimeToFormattedString -DateTime $EndDate))."
      exit 0
    }

    Write-Log -Level INFO -Message "Filtered blobs : $($filteredBlobs.Count)"

    return $filteredBlobs
  } catch {
    Write-ErrorLog -Error $_
    throw
  }
}

function Set-AzBlobsTierToArchive {
  param (
    [Parameter(Mandatory = $true)] [string] $StorageAccountName,
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $ContainerName,
    [Parameter(Mandatory = $true)] [System.Collections.ArrayList] $Blobs,
    [Parameter(Mandatory = $true)] [string] $StorageAccountKey
  )
  $archivedBlobs = New-Object System.Collections.ArrayList
  $count = 0
  try {
    foreach ($blob in $Blobs) {
      $count++
      Write-Log -Level INFO -Message "Setting tier to Archive for blob : $($blob.Name) ($count / $($Blobs.Count))"
      az storage blob set-tier --account-name $StorageAccountName --container-name $ContainerName --account-key $StorageAccountKey --name $blob.Name --tier "Archive"
      [void]$archivedBlobs.Add($blob)
    }
    return $archivedBlobs
  } catch {
    Write-ErrorLog -Error $_
    throw
  }
}

function Set-AzBlobsTierToRehydrate {
  param (
    [Parameter(Mandatory = $true)] [string] $StorageAccountName,
    [Parameter(Mandatory = $true)] [string] $ResourceGroupName,
    [Parameter(Mandatory = $true)] [string] $ContainerName,
    [Parameter(Mandatory = $true)] [string] $Tier,
    [Parameter(Mandatory = $true)] [string] $RehydratePriority,
    [Parameter(Mandatory = $true)] [System.Collections.ArrayList] $Blobs,
    [Parameter(Mandatory = $true)] [string] $StorageAccountKey
  )
  $count = 0
  $rehydratedBlobs = New-Object System.Collections.ArrayList
  try {
    foreach ($blob in $Blobs) {
      $count++
      Write-Log -Level INFO -Message "Rehydrate blob : $($blob.Name) ($count / $($Blobs.Count))"
      az storage blob set-tier --account-name $StorageAccountName --container-name $ContainerName --account-key $StorageAccountKey --name $blob.Name --tier $Tier --rehydrate-priority $RehydratePriority
      [void]$rehydratedBlobs.Add($blob)
    }
    return $rehydratedBlobs
  } catch {
    Write-ErrorLog -Error $_
    throw
  }
}

######## Run Script
######## --- Variables ---
$tenantId = "00000000-0000-0000-0000-000000000000"
$subscriptionId = "00000000-0000-0000-0000-000000000000"
$resourceGroupName = "RgName"
$storageAccountName = "StorageAccountName"
$containerName = "ContainerName"
$blobTierAfterRehydrate = "Hot"
$rehydratePriority = "Standard"
######## --- End of Variables ---

$outputFormat = "{
  Container: container,
  Name: name,
  LastAccessedOn: lastAccessedOn,
  AccessTier: properties.blobTier,
  BlobTierChangeTime: properties.blobTierChangeTime,
  BlobType: properties.blobType,
  BlobTierInferred: properties.blobTierInferred,
  ContentLength: properties.contentLength,
  CreationTime: properties.creationTime,
  LastModified: properties.lastModified,
  RehydrationStatus: properties.rehydrationStatus,
  RemainingRetentionDays: properties.remainingRetentionDays,
  ETag: properties.etag
  RehydratePriority: rehydratePriority,
  Tags: tags,
  VersionId: versionId
}"

Install-RequiredModules -RequiredModules @('Logging')

Add-LoggingTarget -Name Console -Configuration @{
  Level = 'INFO'
}
Add-LoggingTarget -Name File -Configuration @{
  Path = "${PSScriptRoot}\logs\rehydrate.log"
  Encoding = "utf8"
  Level = 'DEBUG'
}
Confirm-AzCliLogin -TenantId $tenantId -SubscriptionId $subscriptionId

$scriptStartTime = Get-TimeNow
# Remove-Item -Path "${PSScriptRoot}\logs\rehydrate.log"
# Remove-Item -Path "${PSScriptRoot}\*.csv"

Write-Log -Level INFO -Message "----------------------------------------------"
Write-Log -Level INFO -Message "Script started at $(ConvertFrom-DateTimeToFormattedString -DateTime $scriptStartTime.DateTime)"

######## ------ 검색 기간 설정 ------
$startDate = Get-DateTimeFromString -DateTimeString "2024-04-03 00:00:00"
$endDate = (Get-Date).AddDays(1)
######## ------ 검색 기간 설정 ------

$storageAccountKey = az storage account keys list `
      --account-name $StorageAccountName `
      --resource-group $ResourceGroupName `
      --query "[0].value" `
      --output tsv

$tierFilter = "Archive"
$blobs = Get-AzBlobListByTier `
  -StorageAccountName $storageAccountName `
  -ResourceGroupName $resourceGroupName `
  -ContainerName $containerName `
  -TierFilter $tierFilter `
  -StorageAccountKey $storageAccountKey `
  -StartDate $startDate `
  -EndDate $endDate `
  -OutputFormat $outputFormat

$targetBlobsCsvFileName = "$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')_${tierFilter}_blobs.csv"
$blobs | Export-Csv -Path "${PSScriptRoot}\$targetBlobsCsvFileName" -Encoding "utf8"

Start-Sleep -Seconds 1
Write-Host "--------------------------------" -ForegroundColor Green
Write-Host "Storage account name : $storageAccountName" -ForegroundColor Green
Write-Host "Container name : $containerName" -ForegroundColor Green
Write-Host "After access tier : $afterAccessTier" -ForegroundColor Green
Write-Host "--------------------------------" -ForegroundColor Green
Write-Host "Check the target blobs file : ${PSScriptRoot}\$targetBlobsCsvFileName" -ForegroundColor Red

$confirmation = $(Write-Host "Are you really sure you want to proceed with the rehydration of the target blob files !? (y/n)" -ForegroundColor Red; Read-Host)

if ($confirmation -ne "y" -or $confirmation -ne "Y") {
    Write-Host "`nOperation cancelled"
    exit 0
}

# $archivedBlobs = Set-AzBlobsTierToArchive `
#   -StorageAccountName $storageAccountName `
#   -ResourceGroupName $resourceGroupName `
#   -ContainerName $containerName `
#   -Blobs $blobs `
#   -StorageAccountKey $storageAccountKey

# $archivedBlobs | Export-Csv -Path "${PSScriptRoot}\$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')_archived_blobs.csv" -Encoding "utf8"

$rehydratedBlobs = Set-AzBlobsTierToRehydrate `
  -StorageAccountName $storageAccountName `
  -ResourceGroupName $resourceGroupName `
  -ContainerName $containerName `
  -Tier $blobTierAfterRehydrate `
  -RehydratePriority $rehydratePriority `
  -Blobs $blobs `
  -StorageAccountKey $storageAccountKey

$rehydratedBlobs | Export-Csv -Path "${PSScriptRoot}\$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')_rehydrated_blobs.csv" -Encoding "utf8"

$scriptEndTime = Get-TimeNow
$scriptDuration = $scriptEndTime.TimeToSeconds - $scriptStartTime.TimeToSeconds
Write-Log -Level INFO -Message "Script Ended at $(ConvertFrom-DateTimeToFormattedString -DateTime $scriptEndTime.DateTime)"
Write-Log -Level INFO -Message "Script Duration : $scriptDuration seconds`n"
exit 0
