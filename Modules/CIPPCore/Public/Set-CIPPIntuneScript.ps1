function Set-CIPPIntuneScript {
    param (
        [Parameter(Mandatory = $true)]
        $ScriptType,
        $Description,
        $DisplayName,
        $RawJSON,
        $OverWrite,
        $AssignTo,
        $ExcludeGroup,
        $Headers,
        $APINAME,
        $tenantFilter
    )

    $ScriptInfo = @(
        [PSCustomObject]@{
            "ScriptType" = 'Windows'
            "url"    = '/deviceManagement/deviceManagementScripts'
        },
        [PSCustomObject]@{
            "ScriptType" = 'MacOS'
            "url"    = '/deviceManagement/deviceShellScripts'
        },
        [PSCustomObject]@{
            "ScriptType" = 'Remediation'
            "url"    = '/deviceManagement/deviceHealthScripts'
        },
        [PSCustomObject]@{
            "ScriptType" = 'Linux'
            "url"    = '/deviceManagement/configurationPolicies'
        }
    )
    $Type = ($ScriptInfo | Where-Object { $_.ScriptType -eq $scriptType })
    $TypeURL = $Type.url

    $JSONObj = $RawJSON | ConvertFrom-Json | Select-Object * -ExcludeProperty "@odata.context", id,createdDateTime,lastModifiedDateTime

    try {

        $CheckExististing = New-GraphGETRequest -uri "https://graph.microsoft.com/beta$TypeURL?`$expand=assignments" -tenantid $tenantFilter.customerId | Where-Object { $_.displayName -eq $DisplayName }
        if ($CheckExististing){
            $StateIsCorrect =   ($CheckExististing.description -eq $DisplayName) -and
                        ($MDMPolicy.discoveryUrl -eq $Description) -and
                        ($CheckExististing.enforceSignatureCheck -eq $JSONObj.enforceSignatureCheck) -and
                        ($CheckExististing.runAs32Bit -eq $JSONObj.runAs32Bit) -and
                        ($CheckExististing.runAsAccount -eq $JSONObj.runAsAccount) -and
                        ($CheckExististing.scriptContent -eq $JSONObj.scriptContent) -and
                        ($CheckExististing.assignments.target -eq $JSONObj.assignments.target)
            if ($StateIsCorrect -eq $true) {
                Write-LogMessage -headers $Headers -API $APINAME -tenant $($tenantFilter.defaultDomainName) -message "Script $($DisplayName) already correctly configured" -sev Info
            } else {

                # $GraphParam = @{
                #     uri = "https://graph.microsoft.com/beta$TypeURL/$($CheckExististing.id)"
                #     tenantid = $tenantFilter.customerId
                #     type = 'PATCH'
                #     body = $RawJSON
                # }
                write-host "Script graphparm: $($GraphParam |ConvertTo-Json -Depth 5)"
                if ($OverWrite) {
                    #$CreateRequest = New-GraphPOSTRequest @GraphParam -erroraction stop
                    Write-LogMessage -headers $Headers -API $APINAME -tenant $($tenantFilter.defaultDomainName) -message "Updated policy $($DisplayName) to template defaults" -Sev 'info'

                    $GraphParam = @{
                        uri = "https://graph.microsoft.com/beta$TypeURL/$($CheckExististing.id)"
                        tenantid = $tenantFilter.customerId
                        type = 'DELETE'
                    }
                    New-GraphPOSTRequest @GraphParam -erroraction stop

                    #"Added Script $($Displayname) to tenant $($TenantName)"
                    ##Missing assignment function
                }
                else{
                    Write-LogMessage -headers $Headers -API $APINAME -tenant $($tenantFilter.defaultDomainName) -message "skipping script $($DisplayName) already exists" -sev Info
                    return "skipping script $($DisplayName) for $($tenantFilter.defaultDomainName) already exists"
                }

            }
        }

        $RawJSON = ConvertTo-Json -InputObject ($JSONObj | Select-Object * -ExcludeProperty *assignments*) -Depth 10 -Compress
        $GraphParam = @{
            uri = "https://graph.microsoft.com/beta$TypeURL"
            tenantid = $tenantFilter.customerId
            type = 'POST'
            body = $RawJSON
        }
        write-host "Script graphparm: $($GraphParam |ConvertTo-Json -Depth 5)"

        $CreateRequest = New-GraphPOSTRequest @GraphParam  -erroraction stop
        Write-LogMessage -headers $Headers -API $APINAME -tenant $($tenantFilter.defaultDomainName) -message "Added policy $($DisplayName) via template" -Sev 'info'
        if ($AssignTo -and $AssignTo -ne 'On') {
            Write-Host "Assigning script to $($AssignTo) with ID $($CreateRequest.id) for tenant $($tenantFilter.defaultDomainName)"
            Write-Host "ID is $($CreateRequest.id)"
            try {
                Write-Host "Script ass: https://graph.microsoft.com/beta$TypeURL/$($CreateRequest.id)/assign"
                Set-CIPPAssignedPolicy -GroupName $AssignTo -PolicyId $CreateRequest.id -PlatformType $ScriptType -Type "Script" -baseuri "https://graph.microsoft.com/beta$TypeURL/$($CreateRequest.id)/assign" -TenantFilter $tenantFilter.customerId -ExcludeGroup $ExcludeGroup -APIName $APINAME -Headers $Headers -errorAction Stop
                Write-LogMessage -headers $Headers -API $APINAME -tenant $($tenantFilter.defaultDomainName) -message "Successfully set assignment to $($AssignTo) for script $($DisplayName) via template" -Sev 'info'
            }
            catch {
                $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
                Write-LogMessage -headers $Headers -API $APINAME -tenant $tenantFilter.defaultDomainName -message "Failed to assign intune script $($DisplayName)." -sev Error -LogData $ErrorMessage
                throw "Failed to assign intune script $($DisplayName). Error: $ErrorMessage"
            }
        }
    }
    catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -headers $Headers -API $APINAME -tenant $tenantFilter.defaultDomainName -message "Failed to add intune script $($DisplayName)." -sev Error -LogData $ErrorMessage
        throw "Failed to add intune script $($DisplayName). Error: $ErrorMessage"
    }
}
