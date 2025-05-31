function Invoke-CIPPStandardMDMScope {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) MDMScope
    .SYNOPSIS
        (Label) Configure MDM user scope
    .DESCRIPTION
        (Helptext) Configures the MDM user scope. This also sets the terms of use, discovery and compliance URL to default URLs.
        (DocsDescription) Configures the MDM user scope. This also sets the terms of use URL, discovery URL and compliance URL to default values.
    .NOTES
        CAT
            Intune Standards
        TAG
        ADDEDCOMPONENT
            {"name":"appliesTo","label":"MDM User Scope?","type":"radio","options":[{"label":"All","value":"all"},{"label":"None","value":"none"},{"label":"Custom Group","value":"selected"}]}
            {"type":"textField","name":"standards.MDMScope.customGroup","label":"Custom Group Name","required":false}
        IMPACT
            Low Impact
        ADDEDDATE
            2025-02-18
        POWERSHELLEQUIVALENT
            Graph API
        RECOMMENDEDBY
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
        https://docs.cipp.app/user-documentation/tenant/standards/list-standards
    #>

    param($Tenant, $Settings)

    $MDMSettings = @(
        [PSCustomObject]@{
            "id" = "d4ebce55-015a-49b5-a083-c84d1797ae8c"
            "complianceUrl" = "https://portal.manage.microsoft.com/?portalAction"
            "discoveryUrl" = "https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc"
            "termsOfUseUrl" = "https://portal.manage.microsoft.com/TermsofUse.aspx"
        },
        [PSCustomObject]@{
            "id" = "0000000a-0000-0000-c000-000000000000"
            "complianceUrl" = "https://portal.manage.microsoft.com/?portalAction=Compliance"
            "discoveryUrl" = "https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc"
            "termsOfUseUrl" = "https://portal.manage.microsoft.com/TermsofUse.aspx"
        }
    )

    #$CurrentInfo = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/0000000a-0000-0000-c000-000000000000?$expand=includedGroups' -tenantid $Tenant
    $CurrentInfo = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies?$expand=includedGroups' -tenantid $Tenant

    $CurrentInfo | Where-Object { $_.id -notin $MDMSettings.id } | ForEach-Object {
        $currentsp = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/servicePrincipals?`$filter=appId eq '$($_.id)'" -tenantid $Tenant
        if ($currentsp) {
            Write-host "MDM Service principal $($_.id) exists, deleting service principal"
            try {
                New-GraphDeleteRequest -uri "https://graph.microsoft.com/beta/servicePrincipals/$($currentsp.id)" -tenantid $Tenant
                Start-Sleep 30
            }
            catch {
                $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                Write-LogMessage -API 'Standards' -tenant $tenant -message "Failed to delete $($MDMSettings.id[0]) MDM service principal" -sev Error -LogData $ErrorMessage
            }
        }

        try {
            Write-host "MDM Service principal $($_.id) missing, creating service principal"
            $NewSP =  New-GraphPOSTRequest -uri "https://graph.microsoft.com/beta/servicePrincipals" -tenantid $Tenant -Body @{"appId" = $_.id}
            Start-Sleep 5
        }
        catch {
            $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
            Write-LogMessage -API 'Standards' -tenant $tenant -message "Failed to create $($MDMSettings.id[0]) MDM service principal" -sev Error -LogData $ErrorMessage
        }
    }

    foreach ($MDMPolicy in $CurrentInfo){
        $MDMSetting = $MDMSettings | Where-Object { $_.id -eq $MDMPolicy.id }
        $StateIsCorrect =   ($MDMPolicy.termsOfUseUrl -eq $MDMSetting.termsOfUseUrl) -and
                        ($MDMPolicy.discoveryUrl -eq $MDMSetting.discoveryUrl) -and
                        ($MDMPolicy.complianceUrl -eq $MDMSetting.complianceUrl) -and
                        ($MDMPolicy.appliesTo -eq $Settings.appliesTo) -and
                        ($Settings.appliesTo -ne 'selected' -or ($MDMPolicy.includedGroups.displayName -contains $Settings.customGroup))

        $CompareField = [PSCustomObject]@{
            termsOfUseUrl = $MDMPolicy.termsOfUseUrl
            discoveryUrl  = $MDMPolicy.discoveryUrl
            complianceUrl = $MDMPolicy.complianceUrl
            appliesTo     = $MDMPolicy.appliesTo
            customGroup   = $MDMPolicy.includedGroups.displayName
        }

        If ($Settings.remediate -eq $true) {
            if ($StateIsCorrect -eq $true) {
                Write-LogMessage -API 'Standards' -tenant $tenant -message "MDM Scope $($MDMPolicy.id) already correctly configured" -sev Info
            } else {
                $GraphParam = @{
                    tenantid     = $tenant
                    Uri          = "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/$($MDMPolicy.id)"
                    ContentType  = 'application/json; charset=utf-8'
                    asApp        = $false
                    type         = 'PATCH'
                    AddedHeaders = @{'Accept-Language' = 0 }
                    Body         = @{
                        'termsOfUseUrl' = $MDMSetting.termsOfUseUrl
                        'discoveryUrl' = $MDMSetting.discoveryUrl
                        'complianceUrl' = $MDMSetting.complianceUrl
                    } | ConvertTo-Json
                }

            try {
                New-GraphPostRequest @GraphParam
                Write-LogMessage -API 'Standards' -tenant $tenant -message 'Successfully configured MDM Scope' -sev Info
            } catch {
                $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                Write-LogMessage -API 'Standards' -tenant $tenant -message 'Failed to configure MDM Scope.' -sev Error -LogData $ErrorMessage
            }

                # Workaround for MDM Scope Assignment error: "Could not set MDM Scope for [TENANT]: Simultaneous patch requests on both the appliesTo and URL properties are currently not supported."
                if ($Settings.appliesTo -ne 'selected') {
                    $GraphParam = @{
                        tenantid = $tenant
                        Uri = "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/$($MDMPolicy.id)"
                        ContentType = 'application/json; charset=utf-8'
                        asApp = $false
                        type = 'PATCH'
                        AddedHeaders = @{'Accept-Language' = 0 }
                        Body = @{
                            'appliesTo' = $Settings.appliesTo
                        } | ConvertTo-Json
                    }

                    try {
                        New-GraphPostRequest @GraphParam
                        Write-LogMessage -API 'Standards' -tenant $tenant -message "Successfully assigned $($Settings.appliesTo) to MDM Scope $($MDMPolicy.id)" -sev Info
                    } catch {
                        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                        Write-LogMessage -API 'Standards' -tenant $tenant -message "Failed to assign $($Settings.appliesTo) to MDM Scope $($MDMPolicy.id)." -sev Error -LogData $ErrorMessage
                    }
                } else {
                    $GroupID = (New-GraphGetRequest -Uri "https://graph.microsoft.com/beta/groups?`$top=999&`$select=id,displayName&`$filter=displayName eq '$($Settings.customGroup)'" -tenantid $tenant -asApp $true).id
                    $GraphParam = @{
                        tenantid = $tenant
                        Uri = "https://graph.microsoft.com/beta/policies/mobileDeviceManagementPolicies/$($MDMPolicy.id)/includedGroups/$ref"
                        ContentType = 'application/json; charset=utf-8'
                        asApp = $false
                        type = 'POST'
                        AddedHeaders = @{'Accept-Language' = 0 }
                        Body = @{
                            '@odata.id' = "https://graph.microsoft.com/odata/groups('$GroupID')"
                        } | ConvertTo-Json
                    }

                    try {
                        New-GraphPostRequest @GraphParam
                        Write-LogMessage -API 'Standards' -tenant $tenant -message "Successfully assigned $($Settings.customGroup) to MDM Scope $($MDMPolicy.id)" -sev Info
                    } catch {
                        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                        Write-LogMessage -API 'Standards' -tenant $tenant -message "Failed to assign $($Settings.customGroup) to MDM Scope $($MDMPolicy.id)." -sev Error -LogData $ErrorMessage
                    }
                }
            }
        }

        if ($Settings.alert -eq $true) {
            if ($StateIsCorrect -eq $true) {
                Write-LogMessage -API 'Standards' -tenant $tenant -message 'MDM Scope is correctly configured' -sev Info
            } else {
                Write-StandardsAlert -message 'MDM Scope is not correctly configured' -object $CompareField -tenant $tenant -standardName 'MDMScope' -standardId $Settings.standardId
                Write-LogMessage -API 'Standards' -tenant $tenant -message 'MDM Scope is not correctly configured' -sev Info
            }
        }

        if ($Settings.report -eq $true) {
            $FieldValue = $StateIsCorrect ? $true : $CompareField
            Set-CIPPStandardsCompareField -FieldName 'standards.MDMScope' -FieldValue $FieldValue -TenantFilter $Tenant
            Add-CIPPBPAField -FieldName 'MDMScope' -FieldValue $StateIsCorrect -StoreAs bool -Tenant $tenant
        }
    }
}
