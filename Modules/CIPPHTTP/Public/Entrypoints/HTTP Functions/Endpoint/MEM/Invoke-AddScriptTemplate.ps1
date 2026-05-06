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


    $graphUrl = "https://graph.microsoft.com/beta"
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
    $TypeURL = ($ScriptInfo | Where-Object { $_.ScriptType -eq $Request.Body.scriptType }).url

    Write-Host "Script: $($Request | ConvertTo-Json -Depth 5)"
    try {

        $parms = @{
            uri = "$graphUrl$TypeURL/$($Request.body.ID)/?`$expand=assignments"
            tenantid = $Request.Body.TenantFilter
        }

        $intuneScript = New-GraphGetRequest @parms -ErrorAction Stop

        $object = [PSCustomObject]@{
            Displayname = $intuneScript.DisplayName
            Description = $intuneScript.Description
            RAWJson     = $intuneScript | ConvertTo-Json -Depth 5 -Compress
            Type        = $Request.body.scriptType
            GUID        = $intuneScript.id
        } | ConvertTo-Json

        $Table = Get-CippTable -tablename 'templates'
        $Table.Force = $true
        Add-CIPPAzDataTableEntity @Table -Entity @{
            JSON         = "$object"
            RowKey       = "$($intuneScript.id)"
            PartitionKey = 'ScriptTemplate'
        }

        Write-LogMessage -headers $Request.Headers -API $APINAME -message "Created script template $($intuneScript.displayName) with GUID $($intuneScript.id) using an original policy from a tenant" -Sev 'Debug'

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
}
