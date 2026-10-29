terraform {
  required_version = ">= 1.3.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.0.0"
    }
  }
}

variable "subscription_id" {
  type        = string
  description = "The target Azure Subscription ID for policy assignment."
}

variable "effect" {
  type        = string
  default     = "Deny"
  description = "Policy effect (Deny, Audit, or Disabled)."
  validation {
    condition     = contains(["Audit", "Deny", "Disabled"], var.effect)
    error_message = "Effect must be Audit, Deny, or Disabled."
  }
}

variable "excluded_resource_group_patterns" {
  type        = list(string)
  default     = [
    "MC_*",
    "databricks-rg-*",
    "cloud-shell-storage-*",
    "*synapse*",
    "AzureBackupRG_*",
    "NetworkWatcherRG*",
    "*ASR*",
    "*SiteRecovery*",
    "*spring*"
  ]
  description = "Resource group name wildcard patterns to exempt from denial."
}

# Policy Definition
resource "azurerm_policy_definition" "private_access" {
  name         = "enforce-disable-public-network-access"
  policy_type  = "Custom"
  mode         = "Indexed"
  display_name = "Enforce Private-Only Access (Disable Public Network Access) with Platform Managed RG Bypass"
  description  = "Denies public network access across all major PaaS services while exempting Azure first-party managed resource groups and automated platform provisioning."

  metadata = jsonencode({
    category = "Network"
    version  = "3.0.0"
  })

  parameters  = file("${path.module}/azurepolicy.parameters.json")
  policy_rule = file("${path.module}/azurepolicy.rules.json")
}

# Subscription-level Policy Assignment
resource "azurerm_subscription_policy_assignment" "private_access_assignment" {
  name                 = "assign-disable-public-network-access"
  subscription_id      = "/subscriptions/${var.subscription_id}"
  policy_definition_id = azurerm_policy_definition.private_access.id
  display_name         = "Enforce Private-Only Access with Platform Managed RG Bypass Assignment"
  description          = "Assigns policy enforcing private network access while exempting managed resource groups."

  parameters = jsonencode({
    effect = {
      value = var.effect
    }
    excludedResourceGroupPatterns = {
      value = var.excluded_resource_group_patterns
    }
  })
}
