<#
.SYNOPSIS
    Discovers, decodes, and tracks expiration dates of SSL certificates in Azure Application Gateways.

.DESCRIPTION
    Azure Application Gateways store directly uploaded SSL certificates as Base64-encoded 'publicCertData'
    without an explicit 'expirationDate' field in Azure Resource Manager (ARM).
    
    This script:
    1. Discovers all Application Gateways across your Azure subscriptions (using Az PowerShell or Azure CLI).
    2. Decodes each directly uploaded certificate's Base64 X.509 binary data to extract:
       - NotAfter (Expiration Date)
       - DaysRemaining until expiration
       - ExpiryStatus (Expired, Critical, Warning, Attention, Healthy)
       - Subject / Common Name (CN)
       - Issuer
       - Thumbprint & Serial Number
    3. For Key Vault integrated certificates, queries Azure Key Vault to resolve the real expiration date.
    4. Outputs results to:
       - Formatted console view with color-coded alerts
       - CSV file export ('AppGateway_Certificate_Expiry_Report.csv')
       - Directly as tags on Application Gateways (using -UpdateGatewayTags) so Azure Resource Graph in your workbook displays the expiry dates natively!
       - Log Analytics Workspace (table: AppGatewayCertificates_CL) if WorkspaceId/Key or -AutoDiscoverWorkspace is set

.PARAMETER WorkspaceId
    Optional: The Workspace ID of your Azure Log Analytics Workspace.

.PARAMETER WorkspaceKey
    Optional: The Primary/Secondary Shared Key of your Log Analytics Workspace.

.PARAMETER AutoDiscoverWorkspace
    Switch: Automatically discovers and uses the first available Log Analytics Workspace in your subscription.

.PARAMETER UpdateGatewayTags
    Switch: Writes tags on the Application Gateways (e.g., CertExpiry_<CertName> = 'YYYY-MM-DD', CertDays_<CertName> = 'xx').
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
    # Auto-discover Log Analytics workspace and sync telemetry
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1 -AutoDiscoverWorkspace

.EXAMPLE
    # Tag Application Gateways AND send to Log Analytics
    .\Sync-AppGatewayCertificatesToLogAnalytics.ps1 -UpdateGatewayTags -AutoDiscoverWorkspace
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
    [switch]$ScanKeyVaults,

    [Parameter(Mandatory = $false)]
    [switch]$NoCsv,

    [Parameter(Mandatory = $false)]
    [string]$CsvReportPath = "AppGateway_Certificate_Expiry_Report.csv",

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
# 1. Query Application Gateways across Subscriptions
# ----------------------------------------------------
Write-Host "`n[1/4] Discovering Application Gateways across subscriptions..." -ForegroundColor Yellow

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
    sslCertificates = properties.sslCertificates,
    httpListeners = properties.httpListeners
"@

$appGateways = @()

# Method A: Search-AzGraph (Az PowerShell)
if (Get-Command Search-AzGraph -ErrorAction SilentlyContinue) {
    try {
        $appGateways = Search-AzGraph -Query $query -First 1000
    } catch {
        Write-Verbose "Search-AzGraph failed ($($_.Exception.Message)). Attempting fallback..."
    }
}

# Method B: Azure CLI Resource Graph (az graph query)
if ($appGateways.Count -eq 0 -and (Get-Command az -ErrorAction SilentlyContinue)) {
    try {
        $cliOutput = az graph query -q $query --output json 2>$null | ConvertFrom-Json
        if ($cliOutput -and $cliOutput.data) {
            $appGateways = $cliOutput.data
        }
    } catch {
        Write-Verbose "Azure CLI Resource Graph query failed ($($_.Exception.Message))."
    }
}

# Method C: Direct Azure CLI fallback across subscriptions
if ($appGateways.Count -eq 0 -and (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Host "  Querying subscriptions via Azure CLI..." -ForegroundColor Gray
    try {
        $subs = az account list --query "[?state=='Enabled'].id" -o json 2>$null | ConvertFrom-Json
        if (-not $subs) {
            $currentSub = az account show --query "id" -o tsv 2>$null
            if ($currentSub) { $subs = @($currentSub.Trim()) }
        }
        foreach ($subId in $subs) {
            $gws = az network application-gateway list --subscription $subId -o json 2>$null | ConvertFrom-Json
            if ($gws) {
                foreach ($gw in $gws) {
                    $appGateways += [PSCustomObject]@{
                        id              = $gw.id
                        name            = $gw.name
                        subscriptionId  = $subId
                        resourceGroup   = $gw.resourceGroup
                        location        = $gw.location
                        tags            = $gw.tags
                        sslCertificates = $gw.sslCertificates
                        httpListeners   = $gw.httpListeners
                    }
                }
            }
        }
    } catch {
        Write-Verbose "Direct az network application-gateway list fallback error: $_"
    }
}

if ($appGateways.Count -eq 0) {
    Write-Error "No Application Gateways found, or unable to authenticate with Azure. Please log in via 'Connect-AzAccount' or 'az login' first."
    return
}

Write-Host "Found $($appGateways.Count) Application Gateway(s)." -ForegroundColor Green

# ----------------------------------------------------
# 2. Decode Certificates & Extract Expiration Dates
# ----------------------------------------------------
Write-Host "`n[2/4] Decoding SSL certificates & resolving expiration dates..." -ForegroundColor Yellow

$decodedCertificates = @()
$tagsToUpdateByGateway = @{}

foreach ($gw in $appGateways) {
    if ($null -eq $gw.sslCertificates) { continue }

    $gwTags = @{}

    foreach ($cert in $gw.sslCertificates) {
        $certProps = if ($cert.properties) { $cert.properties } else { $cert }
        $base64Cert = $certProps.publicCertData
        $keyVaultSecretId = $certProps.keyVaultSecretId

        # Case A: Directly Uploaded Certificate (Base64 X.509)
        if (-not [string]::IsNullOrEmpty($base64Cert)) {
            try {
                $cleanBase64 = $base64Cert.Trim() -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', '' -replace '[\r\n\s]+', ''
                $rawBytes = [System.Convert]::FromBase64String($cleanBase64)
                
                try {
                    $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$rawBytes)
                } catch {
                    $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                    $x509.Import($rawBytes)
                }
                
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

                # Prepare tag entries for live Azure Resource Graph display
                $gwTags["CertExpiry_$($cert.name)"] = $x509.NotAfter.ToString("yyyy-MM-dd")
                $gwTags["CertDays_$($cert.name)"] = $daysRemaining.ToString()
                $gwTags["CertStatus_$($cert.name)"] = $status
            }
            catch {
                Write-Warning "Could not parse certificate '$($cert.name)' on gateway '$($gw.name)': $_"
            }
        }
        # Case B: Key Vault Managed Certificate
        elseif (-not [string]::IsNullOrEmpty($keyVaultSecretId)) {
            $kvExpires = $null
            $kvNotBefore = $null
            $kvThumbprint = ""

            try {
                $uri = [System.Uri]$keyVaultSecretId
                $vaultName = $uri.Host.Split('.')[0]
                $segments = $uri.AbsolutePath.Trim('/').Split('/')
                $secretName = $segments[1]
                $version = if ($segments.Length -gt 2) { $segments[2] } else { "" }

                # Try querying Key Vault via Azure CLI
                if (Get-Command az -ErrorAction SilentlyContinue) {
                    $verArg = if ($version) { "--version $version" } else { "" }
                    $secretInfo = az keyvault secret show --vault-name $vaultName --name $secretName $verArg -o json 2>$null | ConvertFrom-Json
                    if ($secretInfo -and $secretInfo.attributes) {
                        if ($secretInfo.attributes.expires) {
                            $kvExpires = [DateTime]::Parse($secretInfo.attributes.expires)
                        }
                        if ($secretInfo.attributes.notBefore) {
                            $kvNotBefore = [DateTime]::Parse($secretInfo.attributes.notBefore)
                        }
                    }
                    $certInfo = az keyvault certificate show --vault-name $vaultName --name $secretName -o json 2>$null | ConvertFrom-Json
                    if ($certInfo) {
                        if (-not $kvExpires -and $certInfo.attributes.expires) {
                            $kvExpires = [DateTime]::Parse($certInfo.attributes.expires)
                        }
                        if ($certInfo.x509ThumbprintHex) {
                            $kvThumbprint = $certInfo.x509ThumbprintHex
                        }
                    }
                }

                # Try querying Key Vault via Az PowerShell
                if (-not $kvExpires -and (Get-Command Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
                    $kvSecret = if ($version) {
                        Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -Version $version -ErrorAction SilentlyContinue
                    } else {
                        Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -ErrorAction SilentlyContinue
                    }
                    if ($kvSecret -and $kvSecret.Expires) {
                        $kvExpires = $kvSecret.Expires
                    }
                    if ($kvSecret -and $kvSecret.NotBefore) {
                        $kvNotBefore = $kvSecret.NotBefore
                    }
                }
            } catch {
                Write-Verbose "Key Vault lookup error for '$($cert.name)': $_"
            }

            if ($kvExpires) {
                $daysRemaining = [math]::Round(($kvExpires - (Get-Date)).TotalDays)
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
                    CertificateSource = "Key Vault Managed"
                    Subject           = "Key Vault Secret: $secretName"
                    Issuer            = "Key Vault ($vaultName)"
                    Thumbprint        = $kvThumbprint
                    NotBefore         = if ($kvNotBefore) { $kvNotBefore.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                    NotAfter          = $kvExpires.ToString("yyyy-MM-dd HH:mm:ss")
                    DaysRemaining     = $daysRemaining
                    ExpiryStatus      = $status
                    ResourceGroup     = $gw.resourceGroup
                    SubscriptionId    = $gw.subscriptionId
                    Location          = $gw.location
                    TimeGenerated     = [DateTime]::UtcNow.ToString("o")
                }
                $decodedCertificates += [PSCustomObject]$record

                $gwTags["CertExpiry_$($cert.name)"] = $kvExpires.ToString("yyyy-MM-dd")
                $gwTags["CertDays_$($cert.name)"] = $daysRemaining.ToString()
                $gwTags["CertStatus_$($cert.name)"] = $status
            } else {
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
    }

    if ($gwTags.Count -gt 0) {
        $tagsToUpdateByGateway[$gw.id] = @{
            Name          = $gw.name
            ResourceGroup = $gw.resourceGroup
            Tags          = $gwTags
        }
    }
}

Write-Host "Successfully analyzed $($decodedCertificates.Count) SSL certificate(s)." -ForegroundColor Green

# ----------------------------------------------------
# 3. Formatted Console Display
# ----------------------------------------------------
Write-Host "`n[3/4] Application Gateway Certificate Expiry Overview:" -ForegroundColor Yellow

foreach ($item in $decodedCertificates) {
    $color = "Green"
    if ($item.DaysRemaining -lt 0) { $color = "Red" }
    elseif ($item.DaysRemaining -le 30) { $color = "Magenta" }
    elseif ($item.DaysRemaining -le 90) { $color = "Yellow" }

    Write-Host ("  [{0}] Gateway: {1} | Cert: {2} | Source: {3} | Expiry: {4} | Days: {5} | Status: {6}" -f `
        $item.CertificateSource, $item.AppGatewayName, $item.CertificateName, $item.CertificateSource, $item.NotAfter, $item.DaysRemaining, $item.ExpiryStatus) -ForegroundColor $color
}

# ----------------------------------------------------
# 4. Update Gateway Tags (ARG Integration)
# ----------------------------------------------------
if ($UpdateGatewayTags) {
    Write-Host "`n[4/4] Writing Expiration Tags to Application Gateways..." -ForegroundColor Cyan
    foreach ($gwId in $tagsToUpdateByGateway.Keys) {
        $info = $tagsToUpdateByGateway[$gwId]
        Write-Host "  Tagging Application Gateway '$($info.Name)' with expiry dates..." -ForegroundColor Gray
        
        # Method 1: Update-AzTag
        if (Get-Command Update-AzTag -ErrorAction SilentlyContinue) {
            try {
                Update-AzTag -ResourceId $gwId -Tag $info.Tags -Operation Merge -ErrorAction Stop | Out-Null
                Write-Host "  [OK] Tags merged successfully on $($info.Name)" -ForegroundColor Green
                continue
            } catch {
                Write-Verbose "  Update-AzTag failed ($($_.Exception.Message)). Attempting az tag..."
            }
        }
        
        # Method 2: az tag update
        if (Get-Command az -ErrorAction SilentlyContinue) {
            $tagArgs = @()
            foreach ($k in $info.Tags.Keys) {
                $tagArgs += "$k=$($info.Tags[$k])"
            }
            $res = az tag update --resource-id $gwId --operation merge --tags $tagArgs 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] Tags merged successfully via az cli on $($info.Name)" -ForegroundColor Green
            } else {
                Write-Warning "  Could not update tags on $($info.Name). Please verify Write/Tag permissions."
            }
        }
    }
    Write-Host "Tags updated! Azure Resource Graph in your workbook will now show these expiry dates natively!" -ForegroundColor Green
} else {
    Write-Host "`n[Tip] Run with '-UpdateGatewayTags' to write expiration dates directly onto Application Gateways." -ForegroundColor Cyan
    Write-Host "      This enables Azure Resource Graph in your workbook to display them natively with color-coded status badges!" -ForegroundColor Cyan
}

# ----------------------------------------------------
# 5. Optional: Auto-Discover / Sync to Log Analytics
# ----------------------------------------------------
if ($AutoDiscoverWorkspace -and [string]::IsNullOrEmpty($WorkspaceId)) {
    Write-Host "`nAuto-discovering Log Analytics Workspace..." -ForegroundColor Cyan
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
# 6. CSV Export (Application Gateway)
# ----------------------------------------------------
if (-not $NoCsv) {
    $decodedCertificates | Export-Csv -Path $CsvReportPath -NoTypeInformation -Encoding UTF8
    Write-Host "`nReport saved: $CsvReportPath" -ForegroundColor Green
}

# ----------------------------------------------------
# 7. Discover All Azure Key Vault Certificates (if -ScanKeyVaults)
# ----------------------------------------------------
if ($ScanKeyVaults) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host "  Azure Key Vault Certificate Discovery" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "Discovering all Key Vaults across subscriptions..." -ForegroundColor Yellow

    $keyVaults = @()

    if (Get-Command Search-AzGraph -ErrorAction SilentlyContinue) {
        try {
            $keyVaults = Search-AzGraph -Query "resources | where type =~ 'microsoft.keyvault/vaults' | project id, name, resourceGroup, subscriptionId, location" -First 1000
        } catch {}
    }

    if ($keyVaults.Count -eq 0 -and (Get-Command az -ErrorAction SilentlyContinue)) {
        try {
            $cliKv = az graph query -q "resources | where type =~ 'microsoft.keyvault/vaults' | project id, name, resourceGroup, subscriptionId, location" -o json 2>$null | ConvertFrom-Json
            if ($cliKv -and $cliKv.data) {
                $keyVaults = $cliKv.data
            }
        } catch {}
    }

    if ($keyVaults.Count -eq 0 -and (Get-Command az -ErrorAction SilentlyContinue)) {
        try {
            $subs = az account list --query "[?state=='Enabled'].id" -o json 2>$null | ConvertFrom-Json
            if (-not $subs) {
                $currentSub = az account show --query "id" -o tsv 2>$null
                if ($currentSub) { $subs = @($currentSub.Trim()) }
            }
            foreach ($subId in $subs) {
                $kvs = az keyvault list --subscription $subId -o json 2>$null | ConvertFrom-Json
                if ($kvs) {
                    foreach ($k in $kvs) {
                        $keyVaults += [PSCustomObject]@{
                            id             = $k.id
                            name           = $k.name
                            resourceGroup  = $k.resourceGroup
                            subscriptionId = $subId
                            location       = $k.location
                        }
                    }
                }
            }
        } catch {}
    }

    Write-Host "Found $($keyVaults.Count) Azure Key Vault(s). Scanning certificates..." -ForegroundColor Green

    $kvCertificates = @()

    foreach ($kv in $keyVaults) {
        Write-Host "  Scanning certificates in Key Vault '$($kv.name)'..." -ForegroundColor Gray

        if (Get-Command az -ErrorAction SilentlyContinue) {
            try {
                $certs = az keyvault certificate list --vault-name $kv.name -o json 2>$null | ConvertFrom-Json
                if ($certs) {
                    foreach ($c in $certs) {
                        $expires = $null
                        $notBefore = $null
                        if ($c.attributes -and $c.attributes.expires) {
                            $expires = [DateTime]::Parse($c.attributes.expires)
                        }
                        if ($c.attributes -and $c.attributes.notBefore) {
                            $notBefore = [DateTime]::Parse($c.attributes.notBefore)
                        }

                        $daysRemaining = if ($expires) { [math]::Round(($expires - (Get-Date)).TotalDays) } else { 999 }
                        $status = if ($null -eq $expires) { "No Expiry Set" }
                                  elseif ($daysRemaining -lt 0) { "Expired" }
                                  elseif ($daysRemaining -le 30) { "Critical (< 30 Days)" }
                                  elseif ($daysRemaining -le 60) { "Warning (31 - 60 Days)" }
                                  elseif ($daysRemaining -le 90) { "Attention (61 - 90 Days)" }
                                  else { "Healthy (> 90 Days)" }

                        $rec = [ordered]@{
                            VaultName       = $kv.name
                            VaultId         = $kv.id
                            CertificateName = $c.name
                            CertificateId   = $c.id
                            Enabled         = [bool]$c.attributes.enabled
                            Thumbprint      = $c.x509ThumbprintHex
                            NotBefore       = if ($notBefore) { $notBefore.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                            NotAfter        = if ($expires) { $expires.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                            DaysRemaining   = $daysRemaining
                            ExpiryStatus    = $status
                            ResourceGroup   = $kv.resourceGroup
                            SubscriptionId  = $kv.subscriptionId
                            TimeGenerated   = [DateTime]::UtcNow.ToString("o")
                        }
                        $kvCertificates += [PSCustomObject]$rec
                    }
                }
            } catch {}
        }
        elseif (Get-Command Get-AzKeyVaultCertificate -ErrorAction SilentlyContinue) {
            try {
                $certs = Get-AzKeyVaultCertificate -VaultName $kv.name -ErrorAction SilentlyContinue
                if ($certs) {
                    foreach ($c in $certs) {
                        $daysRemaining = if ($c.Expires) { [math]::Round(($c.Expires - (Get-Date)).TotalDays) } else { 999 }
                        $status = if ($null -eq $c.Expires) { "No Expiry Set" }
                                  elseif ($daysRemaining -lt 0) { "Expired" }
                                  elseif ($daysRemaining -le 30) { "Critical (< 30 Days)" }
                                  elseif ($daysRemaining -le 60) { "Warning (31 - 60 Days)" }
                                  elseif ($daysRemaining -le 90) { "Attention (61 - 90 Days)" }
                                  else { "Healthy (> 90 Days)" }

                        $rec = [ordered]@{
                            VaultName       = $kv.name
                            VaultId         = $kv.ResourceId
                            CertificateName = $c.Name
                            CertificateId   = $c.Id
                            Enabled         = [bool]$c.Enabled
                            Thumbprint      = $c.Thumbprint
                            NotBefore       = if ($c.NotBefore) { $c.NotBefore.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                            NotAfter        = if ($c.Expires) { $c.Expires.ToString("yyyy-MM-dd HH:mm:ss") } else { "" }
                            DaysRemaining   = $daysRemaining
                            ExpiryStatus    = $status
                            ResourceGroup   = $kv.ResourceGroupName
                            SubscriptionId  = $kv.subscriptionId
                            TimeGenerated   = [DateTime]::UtcNow.ToString("o")
                        }
                        $kvCertificates += [PSCustomObject]$rec
                    }
                }
            } catch {}
        }
    }

    Write-Host "Successfully decoded $($kvCertificates.Count) certificate(s) across Key Vaults." -ForegroundColor Green

    if ($kvCertificates.Count -gt 0) {
        Write-Host "`nKey Vault Certificate Expiry Overview:" -ForegroundColor Yellow
        foreach ($kvc in $kvCertificates) {
            $color = "Green"
            if ($kvc.DaysRemaining -lt 0) { $color = "Red" }
            elseif ($kvc.DaysRemaining -le 30) { $color = "Magenta" }
            elseif ($kvc.DaysRemaining -le 90) { $color = "Yellow" }

            Write-Host ("  [Vault: {0}] Cert: {1} | Expiry: {2} | Days: {3} | Status: {4} | Enabled: {5}" -f `
                $kvc.VaultName, $kvc.CertificateName, $kvc.NotAfter, $kvc.DaysRemaining, $kvc.ExpiryStatus, $kvc.Enabled) -ForegroundColor $color
        }

        if (-not $NoCsv) {
            $kvCsvPath = "KeyVault_Certificate_Expiry_Report.csv"
            $kvCertificates | Export-Csv -Path $kvCsvPath -NoTypeInformation -Encoding UTF8
            Write-Host "`nKey Vault report saved: $kvCsvPath" -ForegroundColor Green
        }

        if (-not [string]::IsNullOrEmpty($WorkspaceId) -and -not [string]::IsNullOrEmpty($WorkspaceKey)) {
            Write-Host "`nIngesting Key Vault certificates into Log Analytics table 'KeyVaultCertificates_CL'..." -ForegroundColor Cyan
            $kvPayload = $kvCertificates | ConvertTo-Json -Depth 5
            try {
                Send-LogAnalyticsData -CustomerId $WorkspaceId -SharedKey $WorkspaceKey -Body $kvPayload -LogType "KeyVaultCertificates"
                Write-Host "Key Vault certificates synced to Log Analytics successfully!" -ForegroundColor Green
            } catch {
                Write-Warning "Failed to ingest Key Vault certificates: $($_.Exception.Message)"
            }
        }
    }
}

Write-Host "`nProcess complete." -ForegroundColor Cyan
