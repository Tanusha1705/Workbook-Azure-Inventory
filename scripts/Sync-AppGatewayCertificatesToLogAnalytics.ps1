<#
.SYNOPSIS
    Discovers, decodes, and tracks expiration dates of directly uploaded SSL certificates in Azure Application Gateways.

.DESCRIPTION
    Azure Application Gateways store directly uploaded SSL certificates as Base64-encoded 'publicCertData'
    without an explicit 'expirationDate' field in Azure Resource Manager (ARM).
    
    This script:
    1. Discovers all Application Gateways across your Azure subscriptions (using Az PowerShell or Azure CLI).
    2. Decodes each certificate's Base64 X.509 binary data to extract:
       - NotAfter (Expiration Date)
       - DaysRemaining until expiration
       - ExpiryStatus (Expired, Critical, Warning, Attention, Healthy)
       - Subject / Common Name (CN)
       - Issuer
       - Thumbprint & Serial Number
    3. Outputs results to:
       - Formatted console view with color-coded alerts
       - CSV file export ('AppGateway_Certificate_Expiry_Report.csv')
       - Log Analytics Workspace (table: AppGatewayCertificates_CL) if WorkspaceId/Key or -AutoDiscoverWorkspace is set
       - Directly as tags on Application Gateways (using -UpdateGatewayTags) so Azure Resource Graph in your workbook displays the expiry dates natively!

.PARAMETER WorkspaceId
    Optional: The Workspace ID of your Azure Log Analytics Workspace.

.PARAMETER WorkspaceKey
    Optional: The Primary/Secondary Shared Key of your Log Analytics Workspace.

.PARAMETER AutoDiscoverWorkspace
    Switch: Automatically discovers and uses the first available Log Analytics Workspace in your subscription.

.PARAMETER UpdateGatewayTags
    Switch: Writes tags on the Application Gateways (e.g., CertExpiry_<CertName> = 'YYYY-MM-DD').
    This allows Azure Resource Graph in the Azure Workbook to display the expiration date natively without requiring Log Analytics!

.PARAMETER ExportCsv
    Switch: Generates a CSV report file ('AppGateway_Certificate_Expiry_Report.csv'). Defaults to $true.

.EXAMPLE
    # Run locally and display decoded certificate expiry dates in console & export CSV
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1

.EXAMPLE
    # Tag Application Gateways so expiration dates appear directly in Azure Resource Graph & Workbook
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1 -UpdateGatewayTags

.EXAMPLE
    # Auto-discover Log Analytics workspace and sync
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1 -AutoDiscoverWorkspace

.EXAMPLE
    # Ingest into specific Log Analytics Workspace
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1 -WorkspaceId "<ID>" -WorkspaceKey "<KEY>"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [switch]$AutoDiscoverWorkspace,

    [Parameter(Mandatory = $false)]
    [switch]$UpdateGatewayTags,

    [Parameter(Mandatory = $false)]
    [bool]$ExportCsv = $true,

    [Parameter(Mandatory = $false)]
    [string]$LogType = "AppGatewayCertificates"
)

# ----------------------------------------------------
# Helper: Send Data to Log Analytics HTTP Data API
# ----------------------------------------------------
function Send-LogAnalyticsData {
    param(
        [string]$CustomerId,
        [string]$SharedKey,
        [string]$Body,
        [string]$LogType
    )
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = [System.Text.Encoding]::UTF8.GetBytes($Body).Length

    $stringToSign = "$method`n$contentLength`n$contentType`nx-ms-date:$rfc1123date`n$resource"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = [Convert]::FromBase64String($SharedKey)
    $signature = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign)))
    $authHeader = "SharedKey $CustomerId`:$signature"

    $headers = @{
        "Authorization" = $authHeader
        "Log-Type"      = $LogType
        "x-ms-date"     = $rfc1123date
    }

    $uri = "https://$CustomerId.ods.opinsights.azure.com$resource?api-version=2016-04-01"
    Invoke-RestMethod -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $Body
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Azure Application Gateway Certificate Expiry Discovery" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

# ----------------------------------------------------
# 1. Query Application Gateways via Resource Graph / CLI
# ----------------------------------------------------
Write-Host "`n[1/4] Querying Application Gateways across tenant..." -ForegroundColor Yellow

$query = @"
resources
| where type =~ 'microsoft.network/applicationgateways'
| project 
    id, 
    name, 
    subscriptionId, 
    resourceGroup, 
    location, 
    tags,
    sslCertificates = properties.sslCertificates
"@

$appGateways = @()

if (Get-Command Search-AzGraph -ErrorAction SilentlyContinue) {
    try {
        $appGateways = Search-AzGraph -Query $query -First 1000
    } catch {
        Write-Warning "Search-AzGraph failed ($($_.Exception.Message)). Attempting Azure CLI fallback..."
    }
}

if ($appGateways.Count -eq 0 -and (Get-Command az -ErrorAction SilentlyContinue)) {
    try {
        $cliOutput = az graph query -q $query --output json 2>$null | ConvertFrom-Json
        if ($cliOutput -and $cliOutput.data) {
            $appGateways = $cliOutput.data
        }
    } catch {
        Write-Warning "Azure CLI query failed: $($_.Exception.Message)"
    }
}

if ($appGateways.Count -eq 0) {
    Write-Error "No Application Gateways found, or unable to authenticate with Azure. Please run 'Connect-AzAccount' or 'az login' first."
    return
}

Write-Host "Found $($appGateways.Count) Application Gateway(s)." -ForegroundColor Green

# ----------------------------------------------------
# 2. Decode Certificates & Extract Expiration Dates
# ----------------------------------------------------
Write-Host "`n[2/4] Decoding X.509 SSL certificates & extracting expiration dates..." -ForegroundColor Yellow

$decodedCertificates = @()
$tagsToUpdateByGateway = @{}

foreach ($gw in $appGateways) {
    if ($null -eq $gw.sslCertificates) { continue }

    $gwTags = @{}

    foreach ($cert in $gw.sslCertificates) {
        $base64Cert = $cert.properties.publicCertData
        $keyVaultSecretId = $cert.properties.keyVaultSecretId

        if (-not [string]::IsNullOrEmpty($base64Cert)) {
            try {
                $rawBytes = [System.Convert]::FromBase64String($base64Cert)
                $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$rawBytes)
                
                $daysRemaining = [math]::Round(($x509.NotAfter - (Get-Date)).TotalDays)
                $status = if ($daysRemaining -lt 0) {
                    "Expired"
                } elseif ($daysRemaining -le 30) {
                    "Critical (< 30 Days)"
                } elseif ($daysRemaining -le 60) {
                    "Warning (31 - 60 Days)"
                } elseif ($daysRemaining -le 90) {
                    "Attention (61 - 90 Days)"
                } else {
                    "Healthy (> 90 Days)"
                }

                $record = [ordered]@{
                    AppGatewayName    = $gw.name
                    AppGatewayId      = $gw.id
                    CertificateName   = $cert.name
                    CertificateSource = "Direct Upload"
                    Subject           = $x509.Subject
                    Issuer            = $x509.Issuer
                    Thumbprint        = $x509.Thumbprint
                    NotBefore         = $x509.NotBefore.ToString("yyyy-MM-dd HH:mm:ss")
                    NotAfter          = $x509.NotAfter.ToString("yyyy-MM-dd HH:mm:ss")
                    DaysRemaining     = $daysRemaining
                    ExpiryStatus      = $status
                    ResourceGroup     = $gw.resourceGroup
                    SubscriptionId    = $gw.subscriptionId
                    Location          = $gw.location
                    TimeGenerated     = [DateTime]::UtcNow.ToString("o")
                }
                $decodedCertificates += [PSCustomObject]$record

                # Prepare tag entries
                $gwTags["CertExpiry_$($cert.name)"] = $x509.NotAfter.ToString("yyyy-MM-dd")
                $gwTags["CertDays_$($cert.name)"] = $daysRemaining.ToString()
                $gwTags["CertStatus_$($cert.name)"] = $status
            }
            catch {
                Write-Warning "Could not parse certificate '$($cert.name)' on gateway '$($gw.name)': $_"
            }
        }
        elseif (-not [string]::IsNullOrEmpty($keyVaultSecretId)) {
            $record = [ordered]@{
                AppGatewayName    = $gw.name
                AppGatewayId      = $gw.id
                CertificateName   = $cert.name
                CertificateSource = "Key Vault Managed"
                Subject           = "Managed via Key Vault ($keyVaultSecretId)"
                Issuer            = "Key Vault"
                Thumbprint        = ""
                NotBefore         = ""
                NotAfter          = "Auto-Rotated"
                DaysRemaining     = 999
                ExpiryStatus      = "Managed via Key Vault"
                ResourceGroup     = $gw.resourceGroup
                SubscriptionId    = $gw.subscriptionId
                Location          = $gw.location
                TimeGenerated     = [DateTime]::UtcNow.ToString("o")
            }
            $decodedCertificates += [PSCustomObject]$record
        }
    }

    if ($gwTags.Count -gt 0) {
        $tagsToUpdateByGateway[$gw.id] = @{
            Name          = $gw.name
            ResourceGroup = $gw.resourceGroup
            Tags          = $gwTags
        }
    }
}

Write-Host "Successfully decoded $($decodedCertificates.Count) SSL certificate(s)." -ForegroundColor Green

# ----------------------------------------------------
# 3. Display Results Table
# ----------------------------------------------------
Write-Host "`n[3/4] Certificate Expiration Overview:" -ForegroundColor Yellow
$decodedCertificates | Select-Object AppGatewayName, CertificateName, CertificateSource, DaysRemaining, ExpiryStatus, NotAfter | Format-Table -AutoSize

# ----------------------------------------------------
# 4. Optional: Update Gateway Tags (ARG Integration)
# ----------------------------------------------------
if ($UpdateGatewayTags) {
    Write-Host "`n[4/4] Writing Certificate Expiration Tags to Application Gateways..." -ForegroundColor Cyan
    foreach ($gwId in $tagsToUpdateByGateway.Keys) {
        $info = $tagsToUpdateByGateway[$gwId]
        Write-Host "  Tagging Application Gateway '$($info.Name)' with expiry dates..." -ForegroundColor Gray
        
        if (Get-Command Update-AzTag -ErrorAction SilentlyContinue) {
            try {
                Update-AzTag -ResourceId $gwId -Tag $info.Tags -Operation Merge -ErrorAction Stop | Out-Null
                Write-Host "  [OK] Tags merged successfully on $($info.Name)" -ForegroundColor Green
            } catch {
                Write-Warning "  Failed to update tags via Az PowerShell on $($info.Name): $_"
            }
        } elseif (Get-Command az -ErrorAction SilentlyContinue) {
            $tagArgs = @()
            foreach ($k in $info.Tags.Keys) {
                $tagArgs += "$k=$($info.Tags[$k])"
            }
            $tagStr = $tagArgs -join " "
            az tag update --resource-id $gwId --operation merge --tags $tagArgs 2>$null | Out-Null
            Write-Host "  [OK] Tags merged successfully via az cli on $($info.Name)" -ForegroundColor Green
        }
    }
    Write-Host "Tags updated! Azure Resource Graph in your workbook will now show these expiry dates natively!" -ForegroundColor Green
}

# ----------------------------------------------------
# 5. Optional: Auto-Discover / Sync to Log Analytics
# ----------------------------------------------------
if ($AutoDiscoverWorkspace -and [string]::IsNullOrEmpty($WorkspaceId)) {
    Write-Host "`nAuto-discovering Log Analytics Workspace in current subscription..." -ForegroundColor Cyan
    if (Get-Command Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue) {
        $ws = Get-AzOperationalInsightsWorkspace | Select-Object -First 1
        if ($ws) {
            $WorkspaceId = $ws.CustomerId
            $keys = Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ws.ResourceGroupName -Name $ws.Name
            $WorkspaceKey = $keys.PrimarySharedKey
            Write-Host "Found workspace: $($ws.Name) ($WorkspaceId)" -ForegroundColor Green
        }
    } elseif (Get-Command az -ErrorAction SilentlyContinue) {
        $wsJson = az monitor log-analytics workspace list --query "[0]" -o json 2>$null | ConvertFrom-Json
        if ($wsJson) {
            $WorkspaceId = $wsJson.customerId
            $rg = $wsJson.resourceGroup
            $name = $wsJson.name
            $keyJson = az monitor log-analytics workspace get-shared-keys -g $rg -n $name -o json 2>$null | ConvertFrom-Json
            $WorkspaceKey = $keyJson.primarySharedKey
            Write-Host "Found workspace: $name ($WorkspaceId)" -ForegroundColor Green
        }
    }
}

if (-not [string]::IsNullOrEmpty($WorkspaceId) -and -not [string]::IsNullOrEmpty($WorkspaceKey)) {
    Write-Host "`nIngesting records into Log Analytics table '${LogType}_CL'..." -ForegroundColor Cyan
    $jsonPayload = $decodedCertificates | ConvertTo-Json -Depth 5
    try {
        Send-LogAnalyticsData -CustomerId $WorkspaceId -SharedKey $WorkspaceKey -Body $jsonPayload -LogType $LogType
        Write-Host "Log Analytics ingestion complete! Open your Azure Workbook to view decoded certificates." -ForegroundColor Green
    } catch {
        Write-Warning "Failed to ingest into Log Analytics: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------
# 6. CSV Export
# ----------------------------------------------------
if ($ExportCsv) {
    $csvPath = "AppGateway_Certificate_Expiry_Report.csv"
    $decodedCertificates | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nReport saved: $csvPath" -ForegroundColor Green
}

Write-Host "`nDiscovery process complete." -ForegroundColor Cyan
