function Set-CIPPDefaultAPDeploymentProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        $TenantFilter,
        $DisplayName,
        $Description,
        $DeviceNameTemplate,
        $AllowWhiteGlove,
        $CollectHash,
        $UserType,
        $DeploymentMode,
        $HideChangeAccount,
        $AssignTo,
        $HidePrivacy,
        $HideTerms,
        $AutoKeyboard,
        $Headers,
        $Language = 'os-default',
        $APIName = 'Add Default Enrollment Status Page'
    )

    $User = $Request.Headers

    try {
        If ($DeviceNameTemplate -like "*#SHORTNAME#*") {
            $TableProperties = Get-CippTable -tablename 'TenantProperties'
            $TableTenants = Get-CippTable -tablename 'Tenants'

            $Tenant = Get-CIPPAzDataTableEntity @TableTenants -Filter "PartitionKey eq 'Tenants' and defaultDomainName eq '$($tenantfilter)'" -Property RowKey, PartitionKey, customerId, displayName, defaultDomainName


            $Shortname = (Get-CIPPAzDataTableEntity @TableProperties -Filter "PartitionKey eq '$($tenant.customerId)' and RowKey eq 'Shortname'").Value

            if (!$Shortname) {
                Write-LogMessage -Headers $User -API $APIName -tenant $($tenantfilter) -message "Failed adding Autopilot Profile $($Displayname). Error: Tenant ShortName is not set for $($Tenant.defaultDomainName)" -Sev 'Error'
                throw "Tenant ShortName is not set for $($tenantFilter)"
                return
            }
            Write-Host "WAP: shortname $($Shortname)"
            #Write-Host "WAP: Org devTemplate $($DeviceNameTemplate)"
            #Write-Host "WAP: Org devTemplate Type $($DeviceNameTemplate.gettype())"
            $DeviceNameTemplate = $DeviceNameTemplate -replace "#SHORTNAME#", $Shortname
            #Write-Host "WAP: New devTemplate $($DeviceNameTemplate)"
        }
        Write-Host "WAP: language $($Language)"
        $ObjBody = [pscustomobject]@{
            '@odata.type'                            = '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile'
            'displayName'                            = "$($DisplayName)"
            'description'                            = "$($Description)"
            'deviceNameTemplate'                     = "$($DeviceNameTemplate)"
            'language'                               = "$($Language)"
            'enableWhiteGlove'                       = $([bool]($AllowWhiteGlove))
            'deviceType'                             = 'windowsPc'
            'extractHardwareHash'                    = $([bool]($CollectHash))
            'roleScopeTagIds'                        = @()
            'hybridAzureADJoinSkipConnectivityCheck' = $false
            'outOfBoxExperienceSetting'              = @{
                'deviceUsageType'              = "$DeploymentMode"
                'escapeLinkHidden'             = $([bool]($HideChangeAccount))
                'privacySettingsHidden'        = $([bool]($HidePrivacy))
                'eulaHidden'                   = $([bool]($HideTerms))
                'userType'                     = "$UserType"
                'keyboardSelectionPageSkipped' = $([bool]($AutoKeyboard))
            }
        }
        $Body = ConvertTo-Json -InputObject $ObjBody
        Write-Host "WAP: Body $Body"

        $Profiles = New-GraphGETRequest -uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles' -tenantid $TenantFilter | Where-Object -Property displayName -EQ $DisplayName
        if ($Profiles.count -gt 1) {
            $Profiles | ForEach-Object {
                if ($_.id -ne $Profiles[0].id) {
                    if ($PSCmdlet.ShouldProcess($_.displayName, 'Delete duplicate Autopilot profile')) {
                        $null = New-GraphPOSTRequest -uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$($_.id)" -tenantid $TenantFilter -type DELETE
                        Write-LogMessage -Headers $User -API $APIName -tenant $($TenantFilter) -message "Deleted duplicate Autopilot profile $($DisplayName)" -Sev 'Info'
                    }
                }
            }
            $Profiles = $Profiles[0]
        }
        if (!$Profiles) {
            if ($PSCmdlet.ShouldProcess($DisplayName, 'Add Autopilot profile')) {
                $Type = 'Add'
                $GraphRequest = New-GraphPostRequest -uri 'https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles' -body $Body -tenantid $TenantFilter
                Write-LogMessage -Headers $User -API $APIName -tenant $($TenantFilter) -message "Added Autopilot profile $($DisplayName)" -Sev 'Info'
            }
        } else {
            $Type = 'Edit'
            $null = New-GraphPostRequest -uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$($Profiles.id)" -tenantid $TenantFilter -body $Body -type PATCH
            $GraphRequest = $Profiles | Select-Object -Last 1
        }

        if ($AssignTo -eq $true) {
            $AssignBody = '{"target":{"@odata.type":"#microsoft.graph.allDevicesAssignmentTarget"}}'
            if ($PSCmdlet.ShouldProcess($AssignTo, "Assign Autopilot profile $DisplayName")) {
                #Get assignments
                $Assignments = New-GraphGETRequest -uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$($GraphRequest.id)/assignments" -tenantid $TenantFilter
                if (!$Assignments) {
                    $null = New-GraphPOSTRequest -uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeploymentProfiles/$($GraphRequest.id)/assignments" -tenantid $TenantFilter -type POST -body $AssignBody
                }
                Write-LogMessage -Headers $User -API $APIName -tenant $TenantFilter -message "Assigned autopilot profile $($DisplayName) to $AssignTo" -Sev 'Info'
            }
        }
        "Successfully $($Type)ed profile for $TenantFilter"
    } catch {
        $ErrorMessage = Get-CippException -Exception $_
        $Result = "Failed $($Type)ing Autopilot Profile $($DisplayName). Error: $($ErrorMessage.NormalizedError)"
        Write-LogMessage -Headers $User -API $APIName -tenant $TenantFilter -message $Result -Sev 'Error' -LogData $ErrorMessage
        throw $Result
    }
}
