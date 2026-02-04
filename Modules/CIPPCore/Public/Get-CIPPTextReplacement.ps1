function Get-CIPPTextReplacement {
    <#
    .SYNOPSIS
        Replaces text with tenant specific values
    .DESCRIPTION
        Helper function to replace text with tenant specific values
    .PARAMETER TenantFilter
        The tenant filter to use
    .PARAMETER Text
        The text to replace
    .EXAMPLE
        Get-CIPPTextReplacement -TenantFilter 'contoso.com' -Text 'Hello %tenantname%'
    #>
    param (
        [string]$TenantFilter,
        $Text,
        [switch]$EscapeForJson
    )
    if ($Text -isnot [string]) {
        return $Text
    }

    $ReservedVariables = @(
        '%serial%',
        '%systemroot%',
        '%systemdrive%',
        '%temp%',
        '%tenantid%',
        '%tenantfilter%',
        '%initialdomain%',
        '%tenantname%',
        '%partnertenantid%',
        '%samappid%',
        '%userprofile%',
        '%username%',
        '%userdomain%',
        '%windir%',
        '%programfiles%',
        '%programfiles(x86)%',
        '%programdata%',
        '%cippuserschema%',
        '%cippurl%',
        '%defaultdomain%',
        '%organizationid%'
    )

    $Tenant = Get-Tenants -TenantFilter $TenantFilter
    $CustomerId = $Tenant.customerId

    #connect to table, get replacement map. The replacement map will allow users to create custom vars that get replaced by the actual values per tenant. Example:
    # %WallPaperPath% gets replaced by RowKey WallPaperPath which is set to C:\Wallpapers for tenant 1, and D:\Wallpapers for tenant 2

    # Global Variables
    $ReplaceTable = Get-CIPPTable -tablename 'CippReplacemap'
    $GlobalMap = Get-CIPPAzDataTableEntity @ReplaceTable -Filter "PartitionKey eq 'AllTenants'"
    $Vars = @{}
    if ($GlobalMap) {
        foreach ($Var in $GlobalMap) {
            if ($EscapeForJson.IsPresent) {
                # Escape quotes for JSON if not already escaped
                $Var.Value = $Var.Value -replace '(?<!\\)"', '\"'
            }
            $Vars[$Var.RowKey] = $Var.Value
        }
    }

    if ($Tenant) {
        # Tenant Specific Variables
        $ReplaceMap = Get-CIPPAzDataTableEntity @ReplaceTable -Filter "PartitionKey eq '$CustomerId'"
        # If no results found by customerId, try by defaultDomainName
        if (!$ReplaceMap) {
            $ReplaceMap = Get-CIPPAzDataTableEntity @ReplaceTable -Filter "PartitionKey eq '$($Tenant.defaultDomainName)'"
        }
        if ($ReplaceMap) {
            foreach ($Var in $ReplaceMap) {
                if ($EscapeForJson.IsPresent) {
                    # Escape quotes for JSON if not already escaped
                    $Var.Value = $Var.Value -replace '(?<!\\)"', '\"'
                }
                $Vars[$Var.RowKey] = $Var.Value
            }
        }
    }
    # Replace custom variables
    foreach ($Replace in $Vars.GetEnumerator()) {
        $String = '%{0}%' -f $Replace.Key
        if ($string -notin $ReservedVariables) {
            $Text = $Text -replace $String, $Replace.Value
        }
    }

    # Replace EntraID group display name with SID
    while ($Text -match '%CIPPGroup\{(.*?)\}%') {
        $GroupName = $Matches[1] # Extract the value inside the curly braces

        # Fetch the group details from Microsoft Graph
        $EntraIdGroup = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/groups?$select=id,displayName,securityIdentifier&$top=999' -tenantid $CustomerId | Where-Object -Property displayName -EQ $GroupName

        if ($EntraIdGroup) {
            # Replace the current match with the group's securityIdentifier
            $Text = $Text -replace ('%CIPPGroup\{' + [regex]::Escape($GroupName) + '\}%'), $EntraIdGroup.securityIdentifier
        } else {
            Write-LogMessage -API 'Onboarding' -message "Group '$GroupName' not found in EntraID." -Sev 'Error'
            Break
        }
    }



    #default replacements for all tenants: %tenantid% becomes $tenant.customerId, %tenantfilter% becomes $tenant.defaultDomainName, %tenantname% becomes $tenant.displayName
    $Text = $Text -replace '%tenantid%', $Tenant.customerId
    $Text = $Text -replace '%organizationid%', $Tenant.customerId
    $Text = $Text -replace '%tenantfilter%', $Tenant.defaultDomainName
    $Text = $Text -replace '%defaultdomain%', $Tenant.defaultDomainName
    $Text = $Text -replace '%initialdomain%', $Tenant.initialDomainName
    $Text = $Text -replace '%tenantname%', $Tenant.displayName

    # Partner specific replacements
    $Text = $Text -replace '%partnertenantid%', $env:TenantID
    $Text = $Text -replace '%samappid%', $env:ApplicationID

    if ($Text -match '%cippuserschema%') {
        $Schema = Get-CIPPSchemaExtensions | Where-Object { $_.id -match '_cippUser' } | Select-Object -First 1
        $Text = $Text -replace '%cippuserschema%', $Schema.id
    }

    if ($Text -match '%cippurl%') {
        $ConfigTable = Get-CIPPTable -tablename 'Config'
        $Config = Get-CIPPAzDataTableEntity @ConfigTable -Filter "PartitionKey eq 'InstanceProperties' and RowKey eq 'CIPPURL'"
        if ($Config) {
            $Text = $Text -replace '%cippurl%', $Config.Value
        }
    }
    return $Text
}

$d = @"
{  "Displayname": "Ag.L1.P1: Win_ES_AccountProtection_D_Replace Local Admins",  "Description": "Replace all members of local admin group with local user 'SupermuleLocal' and EntraID Group 'Ag.L1: Intune_Users_Local Device Administrators'",  "RAWJson": "{\"name\":\"Ag.L1.P1: Win_ES_AccountProtection_D_Replace Local Admins\",\"description\":\"Replace all members of local admin group with local user 'SupermuleLocal' and EntraID Group 'Ag.L1: Intune_Users_Local Device Administrators'\",\"settings\":[{\"id\":\"0\",\"settingInstance\":{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance\",\"settingDefinitionId\":\"device_vendor_msft_policy_config_localusersandgroups_configure\",\"settingInstanceTemplateReference\":{\"settingInstanceTemplateId\":\"de06bec1-4852-48a0-9799-cf7b85992d45\"},\"groupSettingCollectionValue\":[{\"settingValueTemplateReference\":null,\"children\":[{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance\",\"settingDefinitionId\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup\",\"settingInstanceTemplateReference\":null,\"groupSettingCollectionValue\":[{\"settingValueTemplateReference\":null,\"children\":[{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationChoiceSettingCollectionInstance\",\"settingDefinitionId\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_desc\",\"settingInstanceTemplateReference\":null,\"choiceSettingCollectionValue\":[{\"settingValueTemplateReference\":null,\"value\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_desc_administrators\",\"children\":[]}]},{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance\",\"settingDefinitionId\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_action\",\"settingInstanceTemplateReference\":null,\"choiceSettingValue\":{\"settingValueTemplateReference\":null,\"value\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_action_add_restrict\",\"children\":[]}},{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance\",\"settingDefinitionId\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_userselectiontype\",\"settingInstanceTemplateReference\":null,\"choiceSettingValue\":{\"settingValueTemplateReference\":null,\"value\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_userselectiontype_manual\",\"children\":[{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationSimpleSettingCollectionInstance\",\"settingDefinitionId\":\"device_vendor_msft_policy_config_localusersandgroups_configure_groupconfiguration_accessgroup_users\",\"settingInstanceTemplateReference\":null,\"simpleSettingCollectionValue\":[{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationStringSettingValue\",\"settingValueTemplateReference\":null,\"value\":\"SupermuleLocal\"},{\"@odata.type\":\"#microsoft.graph.deviceManagementConfigurationStringSettingValue\",\"settingValueTemplateReference\":null,\"value\":\"%CIPPGroup{Ag.L1: Intune_Users_Local Device Administrators}%\"}]}]}}]}]}]}]}}],\"platforms\":\"windows10\",\"technologies\":\"mdm\",\"templateReference\":{\"templateId\":\"22968f54-45fa-486c-848e-f8224aa69772_1\",\"templateFamily\":\"endpointSecurityAccountProtection\",\"templateDisplayName\":\"Local user group membership\",\"templateDisplayVersion\":\"Version 1\"}}",  "Type": "Catalog",  "GUID": "032e06e2-3237-46ea-a1de-48b3ba18c8dd"
  }
"@ | ConvertFrom-Json -Depth 100

$text = $d.RAWJson
