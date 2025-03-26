using namespace System.Net

function Invoke-AddScriptTemplate {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        Endpoint.MEM.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint
    $Headers = $Request.Headers
    Write-LogMessage -Headers $Headers -API $APINAME -message 'Accessed this API' -Sev Debug

    $GUID = (New-Guid).GUID

    Write-Host "Script: $($Request | ConvertTo-Json -Depth 5)"
    try {

        $graphUrl = "https://graph.microsoft.com/beta"
        $parms = @{
            uri = "$graphUrl/deviceManagement/deviceManagementScripts/$($Request.body.ID)"
            tenantid = $Request.Body.TenantFilter
        }

        $intuneScript = New-GraphGetRequest @parms | ConvertTo-Json -Depth 5 -Compress

        $Table = Get-CippTable -tablename 'templates'
        $Table.Force = $true
        Add-CIPPAzDataTableEntity @Table -Entity @{
            JSON         = "$intuneScript"
            RowKey       = "$GUID"
            PartitionKey = 'ScriptTemplate'
        }

        Write-LogMessage -headers $Request.Headers -API $APINAME -message "Created script template $($intuneScript.displayName) with GUID $GUID using an original policy from a tenant" -Sev 'Debug'

        $body = [pscustomobject]@{'Results' = 'Successfully added script template' }

        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = $body
        })
    }
    catch {
        Write-LogMessage -headers $Request.Headers -API $APINAME -message "Script Template creation failed: $($_.Exception.Message)" -Sev 'Error'
        $body = [pscustomobject]@{'Results' = 'Failed to add script template' }

        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = $body
        })
    }




    # switch($Request.Method) {
    #     "GET" {
    #         $parms = @{
    #             uri = "$graphUrl/deviceManagement/deviceManagementScripts/$($Request.Query.ScriptId)"
    #             tenantid = $Request.Query.TenantFilter
    #         }

    #         $intuneScript = New-GraphGetRequest @parms
    #         Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    #             StatusCode = [HttpStatusCode]::OK
    #             Body       = $intuneScript
    #         })
    #     }
    #     "PATCH" {
    #         $parms = @{
    #             uri = "$graphUrl/deviceManagement/deviceManagementScripts/$($Request.Body.ScriptId)"
    #             tenantid = $Request.Body.TenantFilter
    #             body = $Request.Body.IntuneScript
    #         }
    #         $patchResult = New-GraphPOSTRequest @parms -type "PATCH"
    #         $body = [pscustomobject]@{'Results' = $patchResult }
    #         Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    #             StatusCode = [HttpStatusCode]::OK
    #             Body       = $body
    #         })
    #     }
    #     "POST" {
    #         Write-Output "Adding script"
    #     }
    # }
}
