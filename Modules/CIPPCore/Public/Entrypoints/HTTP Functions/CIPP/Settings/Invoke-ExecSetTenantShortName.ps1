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

    try {
        $TenantsTable = Get-CippTable -tablename Tenants
        $Tenant = Get-Tenants -TenantFilter $Request.body.value
        $Tenant | Add-Member -MemberType NoteProperty -Name shortName -Value $Request.body.ShortName

        Update-AzDataTableEntity -Force @TenantsTable -Entity $Tenant
        Write-LogMessage -API "SetTenantShortName" -tenant $($Tenant.defaultDomainName) -headers $Request.Headers -message "Set Tenant ShortName '$($Request.body.ShortName)' for customer $($Tenant.defaultDomainName)" -Sev 'Info'
        $body = [pscustomobject]@{'Results' = "Success. We've added ShortName to $($Tenant.defaultDomainName)." }
    }
    catch {
        Write-LogMessage -API "SetTenantShortName" -tenant $($Tenant.defaultDomainName) -headers $Request.Headers -message "Failed to set Tenant ShortName '$($Request.body.ShortName)' for customer $($Tenant.defaultDomainName)" -Sev 'Error'
        $body = [pscustomobject]@{'Results' = "Failed. $($_.Exception.Message)" }
    }

    if (!$body) { $body = @() }

    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })

}
