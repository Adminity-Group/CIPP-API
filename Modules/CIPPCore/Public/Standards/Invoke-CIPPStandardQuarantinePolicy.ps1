function Invoke-CIPPStandardQuarantinePolicy {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) QuarantinePolicy
    .SYNOPSIS
        (Label) Custom Quarantine Policy
    .DESCRIPTION
        (Helptext) This creates a Custom Quarantine Policy
        (DocsDescription) This creates a Custom Quarantine Policy
    .NOTES
        CAT
            Defender Standards
        TAG
            "mdo_safedocuments"
            "mdo_commonattachmentsfilter"
            "mdo_safeattachmentpolicy"
        ADDEDCOMPONENT
            {"type":"select","multiple":false,"label":"Safe Attachment Action","name":"standards.SafeAttachmentPolicy.SafeAttachmentAction","options":[{"label":"Allow","value":"Allow"},{"label":"Block","value":"Block"},{"label":"DynamicDelivery","value":"DynamicDelivery"}]}
            {"type":"select","multiple":false,"label":"QuarantineTag","name":"standards.SafeAttachmentPolicy.QuarantineTag","options":[{"label":"AdminOnlyAccessPolicy","value":"AdminOnlyAccessPolicy"},{"label":"DefaultFullAccessPolicy","value":"DefaultFullAccessPolicy"},{"label":"DefaultFullAccessWithNotificationPolicy","value":"DefaultFullAccessWithNotificationPolicy"}]}
            {"type":"switch","label":"Redirect","name":"standards.SafeAttachmentPolicy.Redirect"}
            {"type":"textField","name":"standards.SafeAttachmentPolicy.RedirectAddress","label":"Redirect Address","required":false}
        IMPACT
            Low Impact
        ADDEDDATE
            2025-03-17
        POWERSHELLEQUIVALENT
            Set-SafeAttachmentPolicy or New-SafeAttachmentPolicy
        RECOMMENDEDBY
            "NgMS"
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
    #>

    param($Tenant, $Settings)

    $PolicyList = @($Settings.Name,'Custom Quarantine Policy')
    $ExistingPolicy = New-ExoRequest -tenantid $Tenant -cmdlet 'Get-QuarantinePolicy' | Where-Object -Property Name -In $PolicyList
    $cmdparams = @{
        ESNEnabled                          = $Settings.ESNEnabled
        IncludeMessagesFromBlockedSenderAddress = $Settings.IncludeMessagesFromBlockedSenderAddress
    }
    Write-Host "Invoke-CIPPStandardQuarantinePolicy: $($Settings | ConvertTo-Json -Depth 5 -Compress)"

    $EndUserQuarantinePermissions = @{
        PermissionToBlockSender = $Settings.PermissionToBlockSender
        PermissionToDelete = $Settings.PermissionToDelete
        PermissionToDownload = $false
        PermissionToPreview = $Settings.PermissionToPreview
        PermissionToRelease = if ($Settings.ReleaseAction -eq "PermissionToRelease") { $true } else { $false }
        PermissionToRequestRelease = if ($Settings.ReleaseAction -eq "PermissionToRequestRelease") { $true } else { $false }
        PermissionToViewHeader = $true
        PermissionToAllowSender = $Settings.PermissionToAllowSender
    }
    Write-Host "Invoke-CIPPStandardQuarantinePolicy: $($EndUserQuarantinePermissions | ConvertTo-Json -Depth 5 -Compress)"

    if ($null -eq $ExistingPolicy.Name) {
        $PolicyName = $PolicyList[0]
        $EndUserQuarantinePermissionsValue = Convert-HashtableToEndUserQuarantinePermissionsValue -InputHashtable $EndUserQuarantinePermissions

        $cmdparams.Add('Name', $PolicyName)
        $cmdparams.Add('EndUserQuarantinePermissionsValue', $EndUserQuarantinePermissionsValue)
        try {
            New-ExoRequest -tenantid $Tenant -cmdlet 'New-QuarantinePolicy' -cmdParams $cmdparams -UseSystemMailbox $true
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Created Custom Quarantine Policy $PolicyName" -sev Info
        }
        catch {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Failed to create Custom Quarantine Policy $PolicyName" -sev Error -LogData $_
        }

    } else {
        $PolicyName = $ExistingPolicy.Name
        $cmdparams.Add('Identity', $PolicyName)

        $CurrentState = $ExistingPolicy | Select-Object Name, ESNEnabled, EndUserQuarantinePermissions, IncludeMessagesFromBlockedSenderAddress, QuarantinePolicyType
        $CurrentStateEndUserQuarantinePermissions = Convert-StringToHashtable -InputString $CurrentState.EndUserQuarantinePermissions
        $StateIsCorrect = ($CurrentState.Name -eq $PolicyName) -and
                        ($CurrentState.ESNEnabled -eq $Settings.ESNEnabled) -and
                        ($CurrentState.IncludeMessagesFromBlockedSenderAddress -eq $Settings.IncludeMessagesFromBlockedSenderAddress) -and
                        ($CurrentState.$CurrentStateEndUserQuarantinePermissions -eq $EndUserQuarantinePermissions)
        if ($StateIsCorrect -eq $true) {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Custom Quarantine Policy already correctly configured $PolicyName" -sev Info
        }
        else{
            try {
                $EndUserQuarantinePermissionsValue = Convert-HashtableToEndUserQuarantinePermissionsValue -InputHashtable $EndUserQuarantinePermissions
                $cmdparams.Add('EndUserQuarantinePermissionsValue', $EndUserQuarantinePermissionsValue)
                New-ExoRequest -tenantid $Tenant -cmdlet 'Set-QuarantinePolicy' -cmdParams $cmdparams -UseSystemMailbox $true
                Write-LogMessage -API 'Standards' -tenant $Tenant -message "Updated Custom Quarantine Policy $PolicyName" -sev Info
            }
            catch {
                Write-LogMessage -API 'Standards' -tenant $Tenant -message "Failed to update Custom Quarantine Policy $PolicyName" -sev Error -LogData $_
            }
        }

    }

}

