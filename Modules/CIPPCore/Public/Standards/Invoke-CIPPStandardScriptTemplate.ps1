function Invoke-CIPPStandardScriptTemplate {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) ScriptTemplate
    .SYNOPSIS
        (Label) Script Template
    .DESCRIPTION
        (Helptext) Deploy and manage Intune templates across devices.
        (DocsDescription) Deploy and manage Intune templates across devices.
    .NOTES
        CAT
            Templates
        MULTIPLE
            True
        DISABLEDFEATURES

        IMPACT
            High Impact
        ADDEDDATE
            2023-12-30
        ADDEDCOMPONENT
            {"type":"autoComplete","multiple":false,"creatable":false,"name":"TemplateList","label":"Select Intune Template","api":{"url":"/api/ListIntuneTemplates","labelField":"Displayname","valueField":"GUID","queryKey":"languages"}}
            {"name":"AssignTo","label":"Who should this template be assigned to?","type":"radio","options":[{"label":"Do not assign","value":"On"},{"label":"Assign to all users","value":"allLicensedUsers"},{"label":"Assign to all devices","value":"AllDevices"},{"label":"Assign to all users and devices","value":"AllDevicesAndUsers"},{"label":"Assign to Custom Group","value":"customGroup"}]}
            {"type":"textField","required":false,"name":"customGroup","label":"Enter the custom group name if you selected 'Assign to Custom Group'. Wildcards are allowed."}
            {"name":"ExcludeGroup","label":"Exclude Groups","type":"textField","required":false,"helpText":"Enter the group name to exclude from the assignment. Wildcards are allowed."}
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
        https://docs.cipp.app/user-documentation/tenant/standards/list-standards/
    #>
    param($Tenant, $Settings)
    ##$Rerun -Type Standard -Tenant $Tenant -Settings $Settings 'intuneTemplate'

    $Request = @{body = $null }

    If ($Settings.remediate -eq $true) {

        $APINAME = 'Standards'
        write-host "Script standards: $($Settings | ConvertTo-Json)"
        write-host "Script standards: $($Tenant | ConvertTo-Json)"
        $Table = Get-CippTable -tablename 'templates'

        foreach ($Setting in $Settings) {
            try {
                $Filter = "PartitionKey eq 'ScriptTemplate' and RowKey eq '$($Setting.TemplateList.value)'"
                $JSONObj = (Get-CippAzDataTableEntity @Table -Filter $Filter).JSON | ConvertFrom-Json
                if (!$JSONObj){
                    Write-LogMessage -API 'Standards' -tenant $tenant -message "Failed to create or update intune script $($JSONObj.displayName). Error: Script Template $($Setting.TemplateList.value) not found" -sev 'Error'
                    return
                }
                $Parameters = @{
                    tenantFilter = $Tenant
                    APIName = $APIName
                    Headers = $Request.Headers
                    displayname = $JSONObj.displayName
                    description = $JSONObj.Description
                    AssignTo = if ($Setting.AssignTo -ne 'on') { $Setting.AssignTo } elseif ($Setting.customGroup) { $Setting.customGroup } else { $null }
                    ExcludeGroup = $Setting.excludeGroup
                    RawJSON = $JSONObj.RAWJson
                    Overwrite = $true
                    ScriptType = $JSONObj.Type
                }

                $null = Set-CIPPIntuneScript @Parameters -errorAction Stop

            } catch {
                $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                Write-LogMessage -API 'Standards' -tenant $tenant -message "Failed to create or update intune script $($JSONObj.displayName). Error: $ErrorMessage" -sev 'Error'
            }
        }


    }
}
