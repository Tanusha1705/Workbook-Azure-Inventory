<#
.SYNOPSIS
    Discovers, decodes, and ingests directly uploaded Azure Application Gateway certificates into Log Analytics.

.DESCRIPTION
    Azure Application Gateways store directly uploaded SSL certificates as Base64-encoded 'publicCertData'
    without an explicit 'expirationDate' field in Azure Resource Manager (ARM).
    This script queries Azure Resource Graph, decodes the X.509 certificate binary, extracts the
    expiration date (NotAfter), Subject, Issuer, and Thumbprint, and optionally sends the records
    to an Azure Log Analytics Workspace for visualization in your Azure Workbook.

.PARAMETER WorkspaceId
    The Workspace ID of your Log Analytics Workspace.

.PARAMETER WorkspaceKey
    The Primary or Secondary Shared Key of your Log Analytics Workspace.

.PARAMETER LogType
    The custom log table name in Log Analytics. Defaults to 'AppGatewayCertificates'.

.EXAMPLE
    # Run locally and display decoded certificate expiry dates in console
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1

.EXAMPLE
    # Ingest into Log Analytics Workspace
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1 -WorkspaceId "xxxx" -WorkspaceKey "yyyy"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceKey,

    [Parameter(Mandatory = $false)]
    [string]$LogType = "AppGatewayCertificates"
)

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

Write-Host "🔍 Querying Azure Resource Graph for all Application Gateways..." -ForegroundColor Cyan

# Fetch all Application Gateways with SSL certificates
$query = @"
resources
| where type =~ 'microsoft.network/applicationgateways'
| project 
    id, 
    name, 
    subscriptionId, 
    resourceGroup, 
    location, 
    sslCertificates = properties.sslCertificates
"@

$appGateways = @()
if (Get-Command Search-AzGraph -ErrorAction SilentlyContinue) {
    $appGateways = Search-AzGraph -Query $query -First 1000
} else {
    Write-Warning "Az.ResourceGraph module not found. Falling back to az cli..."
    $cliOutput = az graph query -q $query --output json | ConvertFrom-Json
    $appGateways = $cliOutput.data
}

$decodedCertificates = @()

foreach ($gw in $appGateways) {
    if ($null -eq $gw.sslCertificates) { continue }

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
                    NotBefore         = $x509.NotBefore.ToString("o")
                    NotAfter          = $x509.NotAfter.ToString("o")
                    DaysRemaining     = $daysRemaining
                    ExpiryStatus      = $status
                    ResourceGroup     = $gw.resourceGroup
                    SubscriptionId    = $gw.subscriptionId
                    Location          = $gw.location
                    TimeGenerated     = [DateTime]::UtcNow.ToString("o")
                }
                $decodedCertificates += [PSCustomObject]$record
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
                Subject           = "Managed via Key Vault"
                Issuer            = "Key Vault"
                Thumbprint        = ""
                NotBefore         = ""
                NotAfter          = ""
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
}

Write-Host "✅ Successfully processed $($decodedCertificates.Count) Application Gateway certificates." -ForegroundColor Green

# Display results in console table
$decodedCertificates | Format-Table AppGatewayName, CertificateName, CertificateSource, DaysRemaining, ExpiryStatus, NotAfter

# If Log Analytics Workspace ID and Key are provided, ingest
if (-not [string]::IsNullOrEmpty($WorkspaceId) -and -not [string]::IsNullOrEmpty($WorkspaceKey)) {
    Write-Host "📤 Ingesting data into Log Analytics Workspace: $WorkspaceId (Table: ${LogType}_CL)..." -ForegroundColor Cyan
    $jsonPayload = $decodedCertificates | ConvertTo-Json -Depth 5
    Send-LogAnalyticsData -CustomerId $WorkspaceId -SharedKey $WorkspaceKey -Body $jsonPayload -LogType $LogType
    Write-Host "🎉 Ingestion complete! The data is now available in your workbook." -ForegroundColor Green
} else {
    Write-Host "ℹ️ To push this data to your Log Analytics Workspace and view in the workbook, run:" -ForegroundColor Yellow
    Write-Host "   .\Sync-AppGatewayCertificatesToLogAnalytics.ps1 -WorkspaceId '<ID>' -WorkspaceKey '<KEY>'" -ForegroundColor Gray
}
