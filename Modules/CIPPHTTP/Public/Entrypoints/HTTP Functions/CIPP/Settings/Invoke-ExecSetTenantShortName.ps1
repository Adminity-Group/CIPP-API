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

    $APINAME = "SetTenantShortName"

    Write-LogMessage -headers $Request.Headers -API $APINAME -message 'Accessed this API' -Sev 'Debug'

    $customerId =  $Request.body.value ?? $Request.Body.customerId


    if (!$customerId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = 'customerId is required'
            })
        return
    }

    if ($Request.body.ShortName -notmatch $regex) {
        Write-LogMessage -API $APIName -tenant $tenantFilter -headers $Request.Headers -message "Failed to set Tenant ShortName '$($Request.body.ShortName)' for customer $tenantFilter. Error: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space" -Sev 'Error'
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = 'Validation Failed: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space'
        })
        return
    }

    try {

        $res = Set-CIPPTenantShortName -Shortname $Request.body.ShortName -customerId $customerId -APIName $APINAME -Headers $Request.Headers -ErrorAction Stop

        $body = [pscustomobject]@{'Results' = "$res" }

        # Associate values to output bindings by calling 'Push-OutputBinding'.
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })
    }
    catch {
        Write-LogMessage -API $APIName -tenant $tenantFilter -headers $Request.Headers -message "Failed to set Tenant ShortName '$($Request.body.ShortName)' for customer $tenantFilter" -Sev 'Error'
        $body = [pscustomobject]@{'Results' = "Failed. $($_.Exception.Message)" }
        # Associate values to output bindings by calling 'Push-OutputBinding'.
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = $body
        })
    }
}
