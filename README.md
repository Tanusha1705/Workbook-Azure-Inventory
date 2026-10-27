# 📊 Azure Inventory & Certificate Expiry Workbooks

Enterprise-grade Azure Monitor Workbooks and ARM deployment templates for complete visibility into your Azure Tenant infrastructure, orphaned resources, and SSL/TLS certificate lifecycles.

---

## 📁 Repository Structure

```
├── armTemplate/
│   ├── certificate_expiry_template.json    # ARM Template: Full Tenant Certificate Expiry Workbook
│   ├── Azure_Orphaned_Resources.json       # ARM Template: Orphaned Resources Discovery
│   └── template.json                       # ARM Template: Azure Full Inventory Workbook
├── galleryTemplate/
│   ├── certificate_expiry_template.json    # Gallery JSON: Full Tenant Certificate Expiry Workbook
│   └── template.json                       # Gallery JSON: Azure Full Inventory Workbook
├── scripts/
│   └── Sync-AppGatewayCertificatesToLogAnalytics.ps1  # Decodes App Gateway direct upload certs & syncs to Log Analytics
├── certificateWorkbook/                    # Standalone self-contained certificate workbook bundle
│   ├── armTemplate/template.json
│   └── galleryTemplate/template.json
└── README.md
```

---

## 🛡️ 1. Azure Full Tenant Certificate Expiry Dashboard

Tracks, monitors, and alerts on SSL/TLS certificate expirations across all subscriptions in your Azure tenant.

### Covered Resource Types & Asset Classes
* **App Service Certificates (`microsoft.web/certificates`)**: Custom and managed SSL certificates with Subject, Issuer, Expiration Date, Days Remaining, Validity, and Thumbprint.
* **App Service Certificate Orders (`microsoft.web/certificateorders`)**: Tracks domain certificate orders, auto-renew status, issuance state, and renewal deadlines.
* **Web Apps & Custom Domain SSL Bindings (`microsoft.web/sites`)**: Maps production App Services and Function Apps to active custom hostnames and SSL bindings (`hostNameSslStates`).
* **Application Gateways (`microsoft.network/applicationgateways`)**:
  * **Directly Uploaded Certificates Support:** Decodes Base64 `publicCertData` into .NET `X509Certificate2` objects to extract exact `NotAfter` expiration dates, Subject, Issuer, and Thumbprint using [`scripts/Sync-AppGatewayCertificatesToLogAnalytics.ps1`](./scripts/Sync-AppGatewayCertificatesToLogAnalytics.ps1).
  * **Key Vault Integration:** Detects whether certificates are integrated with Key Vault (auto-rotatable via unversioned URIs) or manually uploaded.
* **API Management (`microsoft.apimanagement/service`)**: Custom domain endpoint certificates (Gateway, Developer Portal, Management Endpoint) and Key Vault bindings.
* **Azure Front Door & CDN (`microsoft.cdn/profiles/customdomains`)**: Edge custom domains, minimum TLS protocol versions, and managed vs customer certificates.
* **Azure Key Vaults (`microsoft.keyvault/vaults`)**: Posture review (Soft Delete, Purge Protection, Retention, Public Network) + Log Analytics queries for certificate near-expiry audit alerts.

---

## 📋 2. Azure Inventory & Orphaned Resources Dashboard

Provides unified visibility into all compute, networking, data, PaaS, and orphaned resources across your tenant:
* **Overview:** Complete resource count, distribution by location and subscription.
* **Compute:** VMs, VM Scale Sets, Disks, Hybrid/Arc machines, and licensing.
* **PaaS:** App Services, Containers, Data, Events, IoT, ML/AI, Storage, and Azure Virtual Desktop.
* **Networking:** Virtual Networks, Subnets, Public IPs, Network Security Groups, and Route Tables.
* **Orphaned Resources:** Detects unattached disks, unused NICs, unassociated public IPs, empty NSGs, and unattached route tables to reduce cloud spend.

---

## 🚀 Deployment Instructions

### Method 1: Azure Portal (Gallery Import)
1. Open the [Azure Portal](https://portal.azure.com).
2. Go to **Monitor** > **Workbooks**, then click **+ New**.
3. Click the **Advanced Editor (`</>`)** button on the toolbar.
4. Paste the content of any template from `galleryTemplate/`:
   * For Certificate Expiry: [`galleryTemplate/certificate_expiry_template.json`](./galleryTemplate/certificate_expiry_template.json)
   * For Full Inventory: [`galleryTemplate/template.json`](./galleryTemplate/template.json)
5. Click **Apply**, then click the **Save** icon and choose your Subscription and Resource Group.

---

### Method 2: Azure CLI Deployment
Deploy via ARM template using the Azure CLI:

```bash
# Set variables
RG_NAME="rg-monitoring"

# Deploy Certificate Expiry Workbook
az deployment group create \
  --resource-group "$RG_NAME" \
  --template-file "./armTemplate/certificate_expiry_template.json" \
  --parameters workbookDisplayName="Azure Full Tenant Certificate Expiry"

# Deploy Full Inventory Workbook
az deployment group create \
  --resource-group "$RG_NAME" \
  --template-file "./armTemplate/template.json" \
  --parameters workbookDisplayName="Azure Full Inventory"
```

---

### Method 3: Azure PowerShell Deployment
Deploy via Azure PowerShell:

```powershell
$ResourceGroupName = "rg-monitoring"

# Deploy Certificate Expiry Workbook
New-AzResourceGroupDeployment `
  -ResourceGroupName $ResourceGroupName `
  -TemplateFile "./armTemplate/certificate_expiry_template.json" `
  -workbookDisplayName "Azure Full Tenant Certificate Expiry"

# Deploy Full Inventory Workbook
New-AzResourceGroupDeployment `
  -ResourceGroupName $ResourceGroupName `
  -TemplateFile "./armTemplate/template.json" `
  -workbookDisplayName "Azure Full Inventory"
```

---

### Method 4: Directly Uploaded Application Gateway Certificates Sync
To populate exact expiration dates for certificates uploaded directly into Application Gateways:

```powershell
# 1. Run locally to inspect decoded expirations in console
.\scripts\Sync-AppGatewayCertificatesToLogAnalytics.ps1

# 2. Ingest into Log Analytics to display in the workbook
.\scripts\Sync-AppGatewayCertificatesToLogAnalytics.ps1 `
  -WorkspaceId "<Your-Log-Analytics-Workspace-ID>" `
  -WorkspaceKey "<Your-Workspace-Primary-Key>"
```
*(You can also schedule this script as an Azure Automation Runbook or Azure Function on a daily schedule).*
