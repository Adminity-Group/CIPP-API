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

    Write-host "Script: $($Request | ConvertTo-Json -Depth 5)"
    $Displayname = $Request.Body.DisplayName
    $description = $Request.Body.Description
    $AssignTo = $Request.Body.AssignTo
    $ExcludeGroup = $Request.Body.ExcludeGroup
    $ScriptType = $Request.Body.TemplateType
    $RawJSON = $Request.Body.RawJSON
    $Overwrite = $Request.Body.Overwrite

    $Results = @()

    foreach ($Tenant in $Request.Body.tenantFilter) {
        try {
            Write-Host 'Calling Adding Script'
            $null = Set-CIPPIntuneScript -tenantFilter $Tenant -RawJSON $RawJSON -Overwrite $Overwrite -APIName $APIName -Headers $Request.Headers -AssignTo $AssignTo -ExcludeGroup $ExcludeGroup -ScriptType $ScriptType -Displayname $Displayname -Description $description
            $Results += "Added Script $($Displayname) to tenant $($Tenant.addedFields.defaultDomainName)"
            Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $($Tenant) -message "Added policy $($Displayname)" -Sev 'Info'
        } catch {
            $Results += "Failed to add script $($Displayname) to tenant $($Tenant.addedFields.defaultDomainName). $($_.Exception.Message)"
            Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $($Tenant) -message "Failed adding policy $($Displayname). Error: $($_.Exception.Message)" -Sev 'Error'
            continue
        }

    }

    $body = [pscustomobject]@{'Results' = $Results }

    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })

}
