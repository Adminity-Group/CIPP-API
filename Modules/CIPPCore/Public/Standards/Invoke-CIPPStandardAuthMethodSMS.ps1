function Invoke-CIPPStandardAuthMethodSMS {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) AuthMethodSMS
    .SYNOPSIS
        (Label) State of SMS Auth method
    .DESCRIPTION
        (Helptext) This blocks users from using SMS as an MFA method. If a user only has SMS as a MFA method, they will be unable to log in.
        (DocsDescription) Disables SMS as an MFA method for the tenant. If a user only has SMS as a MFA method, they will be unable to sign in.
    .NOTES
        CAT
            Entra (AAD) Standards
        TAG
        ADDEDCOMPONENT
        IMPACT
            High Impact
        ADDEDDATE
            2023-12-18
        POWERSHELLEQUIVALENT
            Update-MgBetaPolicyAuthenticationMethodPolicyAuthenticationMethodConfiguration
        RECOMMENDEDBY
            "CIPP"
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
        https://docs.cipp.app/user-documentation/tenant/standards/list-standards/entra-aad-standards#high-impact
    #>

    param($Tenant, $Settings)
    ##$Rerun -Type Standard -Tenant $Tenant -Settings $Settings 'DisableSMS'

    $state = $Settings.state.value ?? $Settings.state


    if ($Settings.excludeGroup -or $Settings.selectedGroup){
        $TenantGroups = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/groups?$select=id,displayName&$top=999' -tenantid $Tenant
    }

    if ($Settings.excludeGroup){
        $ExcludeList = New-Object System.Collections.Generic.List[System.Object]
        try {
            $GroupNames = $Settings.excludeGroup.Split(',').Trim()
            $GroupIds = $TenantGroups |
                ForEach-Object {
                    foreach ($SingleName in $GroupNames) {
                        write-host "$($SingleName)"
                        if ($_.displayName -like $SingleName) {
                            write-host "$($_.id)"
                            $_.id
                        }
                    }
                }
            foreach ($gid in $GroupIds) {
                $ExcludeList.Add(
                    [PSCustomObject]@{
                        id = $gid
                        targetType = "group"
                    }
                )
            }

            if (!($ExcludeList.id.count -eq $GroupNames.count)){
                Write-LogMessage -API 'Standards' -tenant $Tenant -message "Unable to find exclude group $GroupNames in tenant" -sev Error
                exit 0
            }
        }
        catch {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Failed to find exclude group $GroupNames in tenant" -sev Error -LogData (Get-CippException -Exception $_)
            exit 0
        }
    }

    if ($Settings.selectedGroup){
        $SelectedList = New-Object System.Collections.Generic.List[System.Object]
        try {
            $SelectedGroupNames = $Settings.selectedGroup.Split(',').Trim()

            $GroupIds = $TenantGroups |
                ForEach-Object {
                    foreach ($SingleName in $SelectedGroupNames) {
                        write-host "$($SingleName)"
                        if ($_.displayName -like $SingleName) {
                            write-host "$($_.id)"
                            $_.id
                        }
                    }
                }

            foreach ($gid in $GroupIds) {
                $SelectedList.Add(
                    [PSCustomObject]@{
                        id = $gid
                        targetType = "group"
                    }
                )
            }

            if (!($SelectedList.id.count -eq $SelectedGroupNames.count)){
                Write-LogMessage -API 'Standards' -tenant $Tenant -message "Unable to find selected group $GroupNames in tenant" -sev Error
                exit 0
            }
        }
        catch {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Failed to find selected group $GroupNames in tenant" -sev Error -LogData (Get-CippException -Exception $_)
            exit 0
        }
    }

    $CurrentState = New-GraphGetRequest -Uri 'https://graph.microsoft.com/beta/policies/authenticationmethodspolicy/authenticationMethodConfigurations/SMS' -tenantid $Tenant
    $StateIsCorrect = ($CurrentState.state -eq $Settings.state) -and
                      ($CurrentState.includeTargets.isUsableForSignIn -contains $Settings.isUsableForSignIn) -and
                      ($Settings.selectedUser ? $SelectedList.id -in $CurrentState.includeTargets.id : $true) -and
                      ($Settings.selectedUser ? $ExcludeList.id -in $CurrentState.excludeTargets.id : $true)

    If ($Settings.remediate -eq $true) {
        if ($StateIsCorrect -eq $true) {
            Write-LogMessage -API 'Standards' -tenant $tenant -message 'SMS authentication method is already set correctly.' -sev Info
        } else {
            try {
                #Nået her til
                Set-CIPPAuthenticationPolicy -Tenant $tenant -APIName 'Standards' -AuthenticationMethodId 'SMS_Advanced' -Enabled $false
            } catch {
            }
        }
    }

    if ($Settings.alert -eq $true) {
        if ($StateIsCorrect -eq $true) {
            Write-LogMessage -API 'Standards' -tenant $tenant -message 'SMS authentication method is not enabled' -sev Info
        } else {
            Write-StandardsAlert -message 'SMS authentication method is enabled' -object $CurrentState -tenant $tenant -standardName 'DisableSMS' -standardId $Settings.standardId
            Write-LogMessage -API 'Standards' -tenant $tenant -message 'SMS authentication method is enabled' -sev Info
        }
    }

    if ($Settings.report -eq $true) {
        Set-CIPPStandardsCompareField -FieldName 'standards.DisableSMS' -FieldValue $StateIsCorrect -TenantFilter $Tenant
        Add-CIPPBPAField -FieldName 'DisableSMS' -FieldValue $StateIsCorrect -StoreAs bool -Tenant $tenant
    }
}
