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
            $TenantGroups = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/groups?$select=id,displayName&$top=999' -tenantid $TenantFilter
            Write-Host "NudgeMFA: TenantGroups: $($TenantGroups | ConvertTo-Json -Depth 5)"
            $GroupIds = New-GraphGetRequest -uri 'https://graph.microsoft.com/beta/groups?$select=id,displayName&$top=999' -tenantid $TenantFilter |
                ForEach-Object {
                    foreach ($SingleName in $GroupNames) {
                        if ($_.displayName -like $SingleName) {
                            $_.id
                        }
                    }
                }
                $GroupIds = $rq |
                ForEach-Object {
                    foreach ($SingleName in $GroupNames) {
                        if ($_.displayName -like $SingleName) {
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

$settings = @"
{"Tenant":"folkelarsen.dk","Standard":"NudgeMFA","Settings":{"remediate":true,"alert":false,"report":false,"state":{"label":"Enabled","value":"enabled"},"snoozeDurationInDays":"7","excludeGroup":"Ng.L1: EntraID.Exclude.RegistrationCampaign"},"QueueId":"82c7a16f-cd61-44ad-bcdc-4e304aac603c","templateId":"4058f1ff-e499-473f-986a-90922149358f","QueueName":"NudgeMFA - folkelarsen.dk","FunctionName":"CIPPStandard"}
"@ | ConvertFrom-Json

$settings = $settings.Settings


$rq = @"
[
  {
    "id": "0a77b13d-ce09-4acd-ac1e-d9cc8f9040ba",
    "displayName": "UniversalPrint_b7645db1-2b9a-4584-95e2-39d41c31b046",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "0aacd93d-b2a6-46a1-9330-94cb6d1ac90b",
    "displayName": "All Company",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "0c359bcd-28f6-44e0-b0fd-7fff03472580",
    "displayName": "DHCP Administrators",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "1768a28c-42a7-4e96-8d33-ad410eabb749",
    "displayName": "WSS_ADMIN_WPG",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "1ce110ec-b120-4a6c-a3c6-b80f1c34f063",
    "displayName": "SQLServerSQLAgentUser$CHAMP-SERVER$SBSMONITORING",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "1e69ca9a-dce4-4518-93d4-082acba1ac99",
    "displayName": "navtestorder",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "1eb1c897-1a2b-41f2-835b-2fa56873d50f",
    "displayName": "Alle",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "21c743b1-6e61-46dc-8a88-0704bc487820",
    "displayName": "SQLServer2005SQLBrowserUser$CHAMP-SERVER",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "26c6ecd8-1ed0-443d-8305-78661e4c717f",
    "displayName": "File Server Resource Manager Reports",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "2764df60-0839-4793-a68c-fdcd0697f8c0",
    "displayName": "Sælgere",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "3023d876-d6ed-4fb1-b23c-38b8d5e2df4c",
    "displayName": "All Users",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "3156adad-e943-4ce1-ad73-99036fc0321d",
    "displayName": "WSUS Administrators",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "31a81929-0320-4f3f-87f2-d788a0b21bc1",
    "displayName": "Windows SBS Remote Web Access Users",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "37dddea0-a8eb-4d05-a88b-29ab44934789",
    "displayName": "UniversalPrint_6cfd9c26-b6a0-4c0f-9211-bbcbff103fe2",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "38e5ab1b-affe-486a-9f28-ae1acfed4e81",
    "displayName": "SQLServerFDHostUser$CHAMP-SERVER$SHAREPOINT",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "39ab2493-b9d0-4ef7-b2cc-2c24e5248c1b",
    "displayName": "All Users",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "41a2cd7f-a998-4f43-8ed8-9ee416a9690c",
    "displayName": "Exchange Windows Permissions",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "45e6b1b5-0e02-4473-89f1-ade86a56df35",
    "displayName": "UniversalPrint_88a5f587-d9d0-4328-b7b4-30c6902208cc",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "52cc0314-a8f9-4e7e-a988-5d783e0494e3",
    "displayName": "Exchange Trusted Subsystem",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "5f94b5ba-cae0-4ce7-b32d-103470f3e1c5",
    "displayName": "SQLServerMSSQLUser$CHAMP-SERVER$SHAREPOINT",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "62b01b39-eb9e-420d-bfc3-9ed888dedf4f",
    "displayName": "ExchangeLegacyInterop",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "62eb93cc-a0af-442d-93ac-239b61eacd6d",
    "displayName": "Ng.L1: CA006.Exclude.Mobile.AppProtection",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "69004fd3-a739-416b-9816-5aa8e0b89c6c",
    "displayName": "DnsUpdateProxy",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "6a197863-5dcc-4a6a-a224-9f79ca1c68ea",
    "displayName": "Exchange Servers",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "6bb7e00c-3c00-4413-862b-d6d72927350f",
    "displayName": "Chief Sales Officer",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "7157d96e-f8f8-4215-b366-d8800b422ef3",
    "displayName": "UniversalPrint_e54d06af-7959-4b25-89a2-e847245bc343",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "736bae87-5d7a-44a0-8130-048891b12396",
    "displayName": "Postmaster and Abuse Reporting",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "7aac83b3-464a-4c59-8a04-4bc140011b45",
    "displayName": "Windows SBS Administrators",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "7b5cae72-b750-452e-85ac-a22cd5c8a669",
    "displayName": "Windows SBS Folder Redirection Accounts",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "807a730b-0895-42cb-a76d-582d90e0442a",
    "displayName": "Ng.L1: EntraID.Exclude.RegistrationCampaign",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "867ce0d1-f160-435f-b618-7739946e7c2e",
    "displayName": "SQLServerMSSQLServerADHelperUser$CHAMP-SERVER",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "8ae3514c-5c8e-49e7-a383-44be3a3d3d0a",
    "displayName": "Weber-group",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "90c2efd1-da05-4605-8e9d-2f4917cccc01",
    "displayName": "Windows SBS SharePoint_VisitorsGroup",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "91bc39bc-48ec-4e12-a53d-8ccbf0774f1c",
    "displayName": "Ng.L1: CA.Allow.SMTP",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "93bc97c1-833f-41e2-bff0-84e5aabcd779",
    "displayName": "SQLServerSQLAgentUser$CHAMP-SERVER$SHAREPOINT",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "93dca9b5-2b9d-47ee-a2ba-c08e5e58f109",
    "displayName": "Windows SBS Fax Administrators",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "9622425b-c20b-42ef-afb3-a58b53d7ec0a",
    "displayName": "UniversalPrint_4191142a-5cbe-424d-bfe3-77f9cf7a3892",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "980aab8c-9f8f-4915-aca1-aca7c0b18602",
    "displayName": "WSS_WPG",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "9b0f1ce8-19c3-4c63-9c7a-7056b842cab0",
    "displayName": "Windows SBS Fax Users",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "9bf63338-c879-4177-9e2d-160bffaa3bbd",
    "displayName": "Ng.L1: CA007.Exclude.AnyPlatform.Compliance",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "9dc42473-8551-4353-8b8e-35831e7e8d7b",
    "displayName": "Intern",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "a5138aba-b480-4351-a2a0-d70fd45df74d",
    "displayName": "Windows SBS SharePoint_OwnersGroup",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "a8784c41-166a-452c-b518-d04e3d2dcc07",
    "displayName": "SQLServer2005MSSQLUser$CHAMP-SERVER$MICROSOFT##SSEE",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "a8adeff7-4d21-4753-94f5-527cbcb82512",
    "displayName": "Windows SBS Link Users",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "a9523f85-a2bd-470f-90c5-2366c4c1c248",
    "displayName": "DnsAdmins",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "aaa2c504-ea9f-40f0-bee3-8618f1dac969",
    "displayName": "Folke",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "abfce71b-bd04-418c-9f90-3af38dbb7e4b",
    "displayName": "SQLServer2005MSFTEUser$CHAMP-SERVER$MICROSOFT##SSEE",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "ad84e414-ae12-4262-8dfa-19e2df292aaa",
    "displayName": "UniversalPrint_9da745ae-12c6-4093-9647-fed545be0ca0",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "ae9b06f7-160a-4f55-9053-c055d299c3d6",
    "displayName": "Windows SBS SharePoint_MembersGroup",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "b79dfb60-c2d3-4bcc-a387-72b0f5cfb0e9",
    "displayName": "UniversalPrint_84b4866a-6d0c-410f-9981-754f4c261dcb",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "cf4dee8c-9aed-41ed-bfc2-b6f52f7c1472",
    "displayName": "Windows SBS Virtual Private Network Users",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "cf5fe74c-b8ce-4d03-ab4b-79cb848a2126",
    "displayName": "UniversalPrint_faaad6cf-72cd-4629-aed6-7f93f132e963",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "d1b8e32b-6860-4ad7-b776-e05aa5f01e24",
    "displayName": "SQLServerFDHostUser$CHAMP-SERVER$SBSMONITORING",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "e1aebf67-e25c-4f8b-a953-52237c2a6824",
    "displayName": "Managed Availability Servers",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "e251b58a-7f26-409f-ab93-3b2f9bc26258",
    "displayName": "SQLServerMSSQLUser$CHAMP-SERVER$SBSMONITORING",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "e6346ec8-9f8f-401b-9c5b-aa678e7ddbc6",
    "displayName": "Frokost",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "e953b57e-517c-4470-95b1-7acfc9575ebf",
    "displayName": "Folke Larsen A/S",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "eb09c94a-742d-4f50-85b7-56d7ced52add",
    "displayName": "Exchange All Hosted Organizations",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "ebf57421-4f46-4c05-ab9b-f9ed9f1e15dc",
    "displayName": "UniversalPrint_68d31bed-a509-43fd-89dd-2efb78adc2e9",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "edef6f00-880e-4c90-a82f-9c05e55fd6a1",
    "displayName": "UniversalPrint_936f3829-95fc-40a8-b4ce-72d8e9b96b05",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "f1538235-4e1d-41c1-8567-83f3306ad255",
    "displayName": "User Roles",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "f4b63af8-c734-4c79-af8c-f3b46168d6dc",
    "displayName": "WSUS Reporters",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "f55e677d-21d5-4267-862d-ecb1dce2060d",
    "displayName": "DHCP Users",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "f7c61007-7654-496f-bfc0-9915ee2e619b",
    "displayName": "Ng.L1: CA.BreakGlass",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "f9809ecf-7cef-48d5-a372-71e75fbb66aa",
    "displayName": "Exchange Install Domain Servers",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  },
  {
    "id": "fb2a73f4-cc91-40e1-82c0-66c2bc92d372",
    "displayName": "Windows SBS Admin Tools Group",
    "Tenant": "folkelarsen.dk",
    "CippStatus": "Good"
  }
]
"@ | ConvertFrom-Json
