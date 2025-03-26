using namespace System.Net

Function Invoke-AddScript {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    Write-LogMessage -headers $Request.Headers -API $APINAME -message 'Accessed this API' -Sev 'Debug'

    try {
        Write-host "Script: $($Request.Body | ConvertTo-Json -Depth 5)"

        $Tenants = ($Request.Body.tenantFilter.addedFields)
        if ('AllTenants' -in $Tenants) { $Tenants = (Get-Tenants).defaultDomainName }
        $displayname = $Request.Body.displayName
        $description = $Request.Body.Description
        $AssignTo = if ($Request.Body.AssignTo -ne 'on') { $Request.Body.AssignTo }
        $ExcludeGroup = $Request.Body.excludeGroup
        $Request.body.customGroup ? ($AssignTo = $Request.body.customGroup) : $null
        $RawJSON = $Request.Body.RAWJson
        $Overwrite = $Request.Body.Overwrite
        $ScriptType = $Request.Body.TemplateType

        $Results = foreach ($Tenant in $Tenants) {
            $TenantName = $Tenant.defaultDomainName
            try {
                Write-Host 'Calling Adding Script'
                Set-CIPPIntuneScript -tenantFilter $Tenant -RawJSON $RawJSON -Overwrite $Overwrite -APIName $APIName -Headers $Request.Headers -AssignTo $AssignTo -ExcludeGroup $ExcludeGroup -ScriptType $ScriptType -Displayname $Displayname -Description $description -errorAction Stop
                "Added Script $($Displayname) to tenant $($TenantName)"
                Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $TenantName -message "Added policy $($Displayname)" -Sev 'Info'
            } catch {
                "Failed to add script $($Displayname) to tenant $($TenantName). $($_.Exception.Message)"
                Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $TenantName -message "Failed to add script $($Displayname). Error: $($_.Exception.Message)" -Sev 'Error'
                continue
            }

        }

        $body = [pscustomobject]@{'Results' = @($results) }

        # Associate values to output bindings by calling 'Push-OutputBinding'.
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = $body
            })

    }
    catch {
        $body = [pscustomobject]@{'Results' = $_.Exception.Message }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = $body
        })
        Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $TenantName -message "Failed to proccess request policy. Error: $($_.Exception.Message)" -Sev 'Error'
    }

}
