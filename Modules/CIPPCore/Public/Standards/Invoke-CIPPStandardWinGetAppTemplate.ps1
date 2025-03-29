function Invoke-CIPPStandardWinGetAppTemplate
{
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) IntuneTemplate
    .SYNOPSIS
        (Label) Intune Template
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

    $APIName = "Standards"
    $Request = @{body = $null }


    If ($true -in $Settings.remediate) {
        Write-Host 'WinGet: starting template deploy'
        foreach ($app in $Settings) {
            Write-Host "WinGet: working on WinGet deploy: $($app.displayname) $($app.AppID)"

            try {
                $currentApp = New-GraphGetRequest -uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=(isof(%27microsoft.graph.winGetApp%27))" -tenantid $Tenant | Where-Object { $_.packageIdentifier -eq $app.AppID }
                if ($currentApp) {
                    Write-Host "WinGet: found existing app with id $($app.AppID)"
                    Write-LogMessage -API $APIName -tenant $tenant -message "Found existing app $($app.displayname) with id $($app.AppID)" -sev 'info'
                    continue
                }
                else{
                    $DataRequest = (Invoke-RestMethod -Uri "https://storeedgefd.dsx.mp.microsoft.com/v9.0/packageManifests/$($app.AppID)" -Method GET -ContentType 'Application/json').data

                    if ($DataRequest){
                        try {

                            $WinGetData = [ordered]@{
                                '@odata.type'       = '#microsoft.graph.winGetApp'
                                'displayName'       = "$($DataRequest.Versions.DefaultLocale.PackageName)"
                                'description'       = "$($DataRequest.Versions.DefaultLocale.description)"
                                'packageIdentifier' = "$($app.AppID)"
                                'installExperience' = @{
                                    '@odata.type'  = 'microsoft.graph.winGetAppInstallExperience'
                                    'runAsAccount' = 'system'
                                }
                            }

                            $CompleteObject = [PSCustomObject]@{
                                tenant             = $tenant
                                Applicationname    = $DataRequest.Versions.DefaultLocale.PackageName
                                assignTo           = $assignTo
                                InstallationIntent = $false
                                type               = 'WinGet'
                                IntuneBody         = $WinGetData
                            } | ConvertTo-Json -Depth 15
                            Write-Host "WinGet: $($CompleteObject | ConvertTo-Json -Depth 15)"
                            $Table = Get-CippTable -tablename 'apps'
                            $Table.Force = $true
                            Add-CIPPAzDataTableEntity @Table -Entity @{
                                JSON         = "$CompleteObject"
                                RowKey       = "$((New-Guid).GUID)"
                                PartitionKey = 'apps'
                                status       = 'Not Deployed yet'
                            }
                            "Successfully added Store App for $($Tenant) to queue."
                            Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $tenant -message "Successfully added Store App $($app.Displayname) to queue" -Sev 'Info'
                        } catch {
                            Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $tenant -message "Failed to add Store App $($app.Displayname) to queue" -Sev 'Error'
                            "Failed added Store App for $($Tenant) to queue"
                        }
                    }
                    else {
                        Write-Host "WinGet: No data found for $($app.AppID)"
                        Write-LogMessage -API $APIName -tenant $tenant -message "Failed to find WinGet app $($app.AppID)" -sev 'Error'
                        continue
                    }
                }

            } catch {
                $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                Write-LogMessage -API $APIName -tenant $tenant -message "Failed add WinGet App $($app.displayname) $($app.AppID), Error: $ErrorMessage" -sev 'Error'
            }
        }

    }
}
