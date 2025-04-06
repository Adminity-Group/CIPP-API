using namespace System.Net

Function Invoke-ExecSetTenantShortName {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.AppSettings.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    Write-LogMessage -headers $Request.Headers -API $APINAME -message 'Accessed this API' -Sev 'Debug'

    $customerId = $Request.Query.customerId ?? $Request.Body.customerId
    $regex = '^(?![0-9]+$)(?!.*\s)[a-zA-Z0-9-]{1,6}$'

    if (!$customerId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = 'customerId is required'
            })
        return
    }

    if ($Request.body.ShortName -notmatch $regex) {
        Write-LogMessage -API "SetTenantShortName" -tenant $tenantFilter -headers $Request.Headers -message "Failed to set Tenant ShortName '$($Request.body.ShortName)' for customer $tenantFilter. Error: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space" -Sev 'Error'
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = 'Validation Failed: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space'
        })
        return
    }

    try {
        $Table = Get-CippTable -tablename 'CippReplacemap'

        $VariableName = "shortName"
        $VariableValue = $Request.Body.Value ?? $Request.body.ShortName
        $VariableEntity = @{
            PartitionKey = $customerId
            RowKey       = $VariableName
            Value        = $VariableValue
        }

        Add-CIPPAzDataTableEntity @Table -Entity $VariableEntity -Force
        $Body = @{ Results = "Variable '$VariableName' saved successfully" }

        Write-LogMessage -API "SetTenantShortName" -tenant $tenantFilter -headers $Request.Headers -message "Set Tenant ShortName '$($Request.body.ShortName)' for customer $tenantFilter" -Sev 'Info'
        $body = [pscustomobject]@{'Results' = "Success. We've added ShortName to $tenantFilter." }

        # Associate values to output bindings by calling 'Push-OutputBinding'.
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })
    }
    catch {
        Write-LogMessage -API "SetTenantShortName" -tenant $tenantFilter -headers $Request.Headers -message "Failed to set Tenant ShortName '$($Request.body.ShortName)' for customer $tenantFilter" -Sev 'Error'
        $body = [pscustomobject]@{'Results' = "Failed. $($_.Exception.Message)" }
        # Associate values to output bindings by calling 'Push-OutputBinding'.
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = $body
        })
    }
}
