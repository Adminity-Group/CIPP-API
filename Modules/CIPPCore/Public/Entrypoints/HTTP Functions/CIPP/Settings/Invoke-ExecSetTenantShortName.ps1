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

    $regex = '^(?![0-9]+$)(?!.*\s)[a-zA-Z0-9-]{1,6}$'

    if ($Request.body.ShortName -notmatch $regex) {
        Write-LogMessage -API "SetTenantShortName" -tenant $($Tenant.defaultDomainName) -headers $Request.Headers -message "Failed to set Tenant ShortName '$($Request.body.ShortName)' for customer $($Tenant.defaultDomainName). Error: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space" -Sev 'Error'
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = 'Validation Failed: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space'
        })
        return
    }

    try {
        $TenantsTable = Get-CippTable -tablename Tenants
        $Tenant = Get-Tenants -TenantFilter $Request.body.value

        if ($Tenant.psobject.Members | Where-Object { $_.Name -eq 'shortName' }) {
            $Tenant.shortName = $Request.body.ShortName
        }
        else {
            $Tenant | Add-Member -MemberType NoteProperty -Name shortName -Value $Request.body.ShortName
        }

        Update-AzDataTableEntity -Force @TenantsTable -Entity $Tenant
        Write-LogMessage -API "SetTenantShortName" -tenant $($Tenant.defaultDomainName) -headers $Request.Headers -message "Set Tenant ShortName '$($Request.body.ShortName)' for customer $($Tenant.defaultDomainName)" -Sev 'Info'
        $body = [pscustomobject]@{'Results' = "Success. We've added ShortName to $($Tenant.defaultDomainName)." }

        # Associate values to output bindings by calling 'Push-OutputBinding'.
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })
    }
    catch {
        Write-LogMessage -API "SetTenantShortName" -tenant $($Tenant.defaultDomainName) -headers $Request.Headers -message "Failed to set Tenant ShortName '$($Request.body.ShortName)' for customer $($Tenant.defaultDomainName)" -Sev 'Error'
        $body = [pscustomobject]@{'Results' = "Failed. $($_.Exception.Message)" }
        # Associate values to output bindings by calling 'Push-OutputBinding'.
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = $body
        })
    }
}
$Tenant = [pscustomobject]@{}
$Tenant.psobject.Members | Where-Object { $_.Name -eq 'shortName' }
