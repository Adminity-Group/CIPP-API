function Set-CIPPIntuneScript {
    param (
        [Parameter(Mandatory = $true)]
        $ScriptType,
        $Description,
        $DisplayName,
        $RawJSON,
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
    $TypeURL = ($ScriptInfo | Where-Object { $_.ScriptType -eq $scriptType }).url

    "/deviceManagement/deviceManagementScripts"

    $JSONObj = $RawJSON | ConvertFrom-Json | Select-Object * -ExcludeProperty "@odata.context", id, *assignments*,createdDateTime,lastModifiedDateTime

    try {
        $RawJSON = ConvertTo-Json -InputObject $JSONObj -Depth 10 -Compress
        $CheckExististing = New-GraphGETRequest -uri "https://graph.microsoft.com/beta$TypeURL" -tenantid $tenantFilter | Where-Object { $_.displayName -eq $DisplayName }
        if ($CheckExististing){
            $StateIsCorrect =   ($CheckExististing.description -eq $DisplayName) -and
                        ($MDMPolicy.discoveryUrl -eq $Description) -and
                        ($CheckExististing.enforceSignatureCheck -eq $JSONObj.enforceSignatureCheck) -and
                        ($CheckExististing.runAs32Bit -eq $JSONObj.runAs32Bit) -and
                        ($CheckExististing.runAsAccount -eq $JSONObj.runAsAccount) -and
                        ($CheckExististing.scriptContent -eq $JSONObj.scriptContent)
            if ($StateIsCorrect -eq $true) {
                Write-LogMessage -headers $Headers -API $APINAME -tenant $tenant -message "MDM Scope $($MDMPolicy.id) already correctly configured" -sev Info
            } else {
                $GraphParam = @{
                    uri = "https://graph.microsoft.com/beta$TypeURL/$($CheckExististing.id)"
                    tenantid = $tenantFilter
                    type = 'PATCH'
                    body = $RawJSON
                }
                $CreateRequest = New-GraphPOSTRequest @GraphParam
                Write-LogMessage -headers $Headers -API $APINAME -tenant $($tenantFilter) -message "Updated policy $($DisplayName) to template defaults" -Sev 'info'
            }
        }
        else {
            $CreateRequest = New-GraphPOSTRequest -uri "https://graph.microsoft.com/beta$TypeURL" -tenantid $tenantFilter -type POST -body $RawJSON
            Write-LogMessage -headers $Headers -API $APINAME -tenant $($tenantFilter) -message "Added policy $($DisplayName) via template" -Sev 'info'
        }
    }
    catch {
        $ErrorMessage = Get-NormalizedError -Message $_.Exception.Message
        Write-LogMessage -headers $Headers -API $APINAME -tenant $tenant -message "Failed to add intune script $($DisplayName)." -sev Error -LogData $ErrorMessage
    }
}
