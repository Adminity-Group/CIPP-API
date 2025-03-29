function Invoke-CIPPStandardNudgeMFA {
    <#
    .FUNCTIONALITY
        Internal
    .COMPONENT
        (APIName) NudgeMFA
    .SYNOPSIS
        (Label) Sets the state for the request to setup Authenticator
    .DESCRIPTION
        (Helptext) Sets the state of the registration campaign for the tenant
        (DocsDescription) Sets the state of the registration campaign for the tenant. If enabled nudges users to set up the Microsoft Authenticator during sign-in.
    .NOTES
        CAT
            Entra (AAD) Standards
        TAG
        ADDEDCOMPONENT
            {"type":"autoComplete","multiple":false,"creatable":false,"label":"Select value","name":"standards.NudgeMFA.state","options":[{"label":"Enabled","value":"enabled"},{"label":"Disabled","value":"disabled"}]}
            {"type":"number","name":"standards.NudgeMFA.snoozeDurationInDays","label":"Number of days to allow users to skip registering Authenticator (0-14, default is 1)","defaultValue":1}
        IMPACT
            Low Impact
        ADDEDDATE
            2022-12-08
        POWERSHELLEQUIVALENT
            Update-MgPolicyAuthenticationMethodPolicy
        RECOMMENDEDBY
        UPDATECOMMENTBLOCK
            Run the Tools\Update-StandardsComments.ps1 script to update this comment block
    .LINK
        https://docs.cipp.app/user-documentation/tenant/standards/list-standards/entra-aad-standards#low-impact
    #>

    param($Tenant, $Settings)
    ##$Rerun -Type Standard -Tenant $Tenant -Settings $Settings 'NudgeMFA'
    Write-Host "NudgeMFA: $($Settings | ConvertTo-Json -Compress)"
    # Get state value using null-coalescing operator
    $state = $Settings.state.value ?? $Settings.state

    $ExcludeList = New-Object System.Collections.Generic.List[System.Object]

    if ($Settings.excludeGroup){
        Write-Host "NudgeMFA: We're supposed to exclude a custom group. The group is $($Settings.excludeGroup)"
        try {
            $GroupNames = $Settings.excludeGroup.Split(',').Trim()
            $TenantGroups = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/groups?$select=id,displayName&$top=999' -tenantid $Tenant
            Write-Host "NudgeMFA: TenantGroups: $($TenantGroups | ConvertTo-Json -Depth 5)"
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
            write-host "NudgeMFA: GroupIds: $($GroupIds | ConvertTo-Json)"
            foreach ($gid in $GroupIds) {
                $ExcludeList.Add(
                    [PSCustomObject]@{
                        id = $gid
                        targetType = "group"
                    }
                )
            }
            write-host "NudgeMFA: ExcludeList: $($ExcludeList | ConvertTo-Json)"
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


    try {
        $CurrentState = New-GraphGetRequest -Uri 'https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy' -tenantid $Tenant
        $StateIsCorrect = ($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.state -eq $state) -and
                        ($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.snoozeDurationInDays -eq $Settings.snoozeDurationInDays) -and
                        ($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.enforceRegistrationAfterAllowedSnoozes -eq $true) -and
                        ($ExcludeList.id -in $CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.excludeTargets.id)
    } catch {
        Write-LogMessage -API 'Standards' -tenant $Tenant -message 'Failed to get Authenticator App Nudge state, check your permissions and try again' -sev Error -LogData (Get-CippException -Exception $_)
        exit 0
    }

    if ($Settings.remediate -eq $true) {
        $defaultIncludeTargets = @(
            @{
                id = 'all_users'
                targetType = 'group'
                targetedAuthenticationMethod = 'microsoftAuthenticator'
            }
        )

        $CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.excludeTargets | ForEach-Object {$ExcludeList.add($_)}

        $StateName = $Settings.state ? 'Enabled' : 'Disabled'
        try {
            $GraphRequest = @{
                tenantid    = $Tenant
                uri         = 'https://graph.microsoft.com/beta/policies/authenticationMethodsPolicy'
                AsApp       = $false
                Type        = 'PATCH'
                ContentType = 'application/json'
                Body        = @{
                    registrationEnforcement = @{
                        authenticationMethodsRegistrationCampaign = @{
                            state                                  = $state
                            snoozeDurationInDays                   = $Settings.snoozeDurationInDays
                            enforceRegistrationAfterAllowedSnoozes = $true
                            includeTargets                         = ($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.includeTargets.Count -gt 0) ? $CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.includeTargets : $defaultIncludeTargets
                            excludeTargets                         = $ExcludeList
                        }
                    }
                } | ConvertTo-Json -Depth 10 -Compress
            }
            Write-Host "NudgeMFA Request: $($GraphRequest | ConvertTo-Json -Depth 5)"
            New-GraphPostRequest @GraphRequest
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "$StateName Authenticator App Nudge with a snooze duration of $($Settings.snoozeDurationInDays)" -sev Info
        } catch {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Failed to set Authenticator App Nudge to $state. Error: $($_.Exception.message)" -sev Error -LogData $_
        }
    }

    if ($Settings.alert -eq $true) {
        if ($StateIsCorrect -eq $true) {
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Authenticator App Nudge is enabled with a snooze duration of $($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.snoozeDurationInDays)" -sev Info
        } else {
            Write-StandardsAlert -message "Authenticator App Nudge is not enabled with a snooze duration of $($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.snoozeDurationInDays)" -object ($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign | Select-Object snoozeDurationInDays, state) -tenant $Tenant -standardName 'NudgeMFA' -standardId $Settings.standardId
            Write-LogMessage -API 'Standards' -tenant $Tenant -message "Authenticator App Nudge is not enabled with a snooze duration of $($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign.snoozeDurationInDays)" -sev Info
        }
    }

    if ($Settings.report -eq $true) {
        $state = $StateIsCorrect ? $true : ($CurrentState.registrationEnforcement.authenticationMethodsRegistrationCampaign | Select-Object snoozeDurationInDays, state)
        Set-CIPPStandardsCompareField -FieldName 'standards.NudgeMFA' -FieldValue $state -Tenant $Tenant
        Add-CIPPBPAField -FieldName 'NudgeMFA' -FieldValue $StateIsCorrect -StoreAs bool -Tenant $Tenant
    }
}



$groups = @"
[
  {
    "id": "05d0e47f-1f10-47c0-83cd-8c47b775170d",
    "displayName": "Ng.PIM.Cust.Az.Sub.Contributor"
  },
  {
    "id": "071abcea-19f3-438e-b7fc-020dd37e2ccc",
    "displayName": "Azure ATP ngmsdk Users"
  },
  {
    "id": "1c97b7e7-0d96-4d0c-87f2-9a0588d3383e",
    "displayName": "M365 GDAP Cloud Application Administrator"
  },
  {
    "id": "1e2a903a-598e-4940-8cdc-542fbcda5583",
    "displayName": "All Company"
  },
  {
    "id": "210e9a6c-2e87-43bf-b3eb-82b2442d1aa2",
    "displayName": "M365 GDAP Exchange Administrator"
  },
  {
    "id": "28cf90e0-841f-4544-8376-8cd31277402b",
    "displayName": "PartnerCenter_MPNAdmin"
  },
  {
    "id": "2c16e5bf-f387-45fd-b32e-96ba92ebdd8c",
    "displayName": "M365 GDAP Application Administrator"
  },
  {
    "id": "2db46348-cf95-400e-8a57-e2ebd9881b21",
    "displayName": "NgMS Consult"
  },
  {
    "id": "2dba24d6-8526-485f-b109-973a18d2d0b7",
    "displayName": "Ng: SG_Intune.AS.Test Users"
  },
  {
    "id": "2fbb07cb-ea8c-4754-970a-f26e02afc331",
    "displayName": "M365 GDAP Cloud Device Administrator"
  },
  {
    "id": "45fed89b-7431-4f12-9ea1-32ba0b052669",
    "displayName": "M365 GDAP Helpdesk Administrator"
  },
  {
    "id": "49154ebf-f4c1-4a9f-9ecc-261411fc476d",
    "displayName": "M365 GDAP Intune Administrator"
  },
  {
    "id": "4ee03f26-b2ad-4cb7-af49-952fc9c39405",
    "displayName": "SalesAgents"
  },
  {
    "id": "530e6fbe-204f-41e3-8574-7a7c9a3df1a0",
    "displayName": "M365 GDAP Privileged Authentication Administrator"
  },
  {
    "id": "683f63ac-cefe-411b-bd1d-b5ddd8606ab1",
    "displayName": "Azure ATP ngmsdk Viewers"
  },
  {
    "id": "6a30a450-1a20-49fd-b5aa-312a744dd379",
    "displayName": "Ng.PIM.Cust.Az.Sub.Reader"
  },
  {
    "id": "71041b9d-8f95-49c0-944d-b165909e8bc2",
    "displayName": "M365 GDAP SharePoint Administrator"
  },
  {
    "id": "7515b87e-c8f3-4c5b-b35b-4a203960dd02",
    "displayName": "NgSentinel"
  },
  {
    "id": "84bc732b-744c-4774-a986-aaa8bc7173b6",
    "displayName": "M365 GDAP Privileged Role Administrator"
  },
  {
    "id": "858a24d3-729b-47f0-8375-2190c7444d29",
    "displayName": "M365 GDAP Security Administrator"
  },
  {
    "id": "9c6ca232-2073-4466-b369-20820743218c",
    "displayName": "M365 GDAP License Administrator"
  },
  {
    "id": "a19576ea-8c41-442d-a47a-f0b65f6f409b",
    "displayName": "M365 GDAP User Administrator"
  },
  {
    "id": "aa532010-f144-4cad-9c33-fba767e3a043",
    "displayName": "M365 GDAP Authentication Policy Administrator"
  },
  {
    "id": "ad6352f5-5bee-44b4-89d0-9859d2b52bc0",
    "displayName": "M365 GDAP Billing Administrator"
  },
  {
    "id": "b8f963c7-bfd3-464a-b758-a5bbe2b8da9c",
    "displayName": "M365 GDAP Global Reader"
  },
  {
    "id": "c8dc5c2c-ee84-46c3-80dc-436005c90cf6",
    "displayName": "All Users"
  },
  {
    "id": "d0da3416-b9ec-4978-9992-d55fdc0b16ba",
    "displayName": "HelpdeskAgents"
  },
  {
    "id": "d8128a22-a750-43e9-9b46-3f35f0152a7f",
    "displayName": "M365 GDAP Cloud App Security Administrator"
  },
  {
    "id": "d8dd5a7a-e2a5-43f1-afd9-fc7c44629e29",
    "displayName": "AdminAgents"
  },
  {
    "id": "d9d3eee6-80fe-4f5b-937f-873ed814fda5",
    "displayName": "Azure ATP ngmsdk Administrators"
  },
  {
    "id": "da9927e3-695f-40e2-b8bc-ad92081cf785",
    "displayName": "M365 GDAP Service Support Administrator"
  },
  {
    "id": "fd17768b-7a1c-43c6-88d4-398f0ca59d39",
    "displayName": "NgMS.Sec.Ass.Acronis SSO"
  },
  {
    "id": "fd77a303-fbef-4cbb-9964-c87e908f6c74",
    "displayName": "M365 GDAP Teams Administrator"
  }
]
"@ | ConvertFrom-Json


$settings = @"
{"Tenant":"folkelarsen.dk","Standard":"NudgeMFA","Settings":{"remediate":true,"alert":false,"report":false,"state":{"label":"Enabled","value":"enabled"},"snoozeDurationInDays":"7","excludeGroup":"Ng.L1: EntraID.Exclude.RegistrationCampaign"},"QueueId":"82c7a16f-cd61-44ad-bcdc-4e304aac603c","templateId":"4058f1ff-e499-473f-986a-90922149358f","QueueName":"NudgeMFA - folkelarsen.dk","FunctionName":"CIPPStandard"}
"@ | ConvertFrom-Json

$settings = $settings.Settings
