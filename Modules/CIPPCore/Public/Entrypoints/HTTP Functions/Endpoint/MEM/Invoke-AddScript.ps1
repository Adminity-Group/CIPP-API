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

        $Tenants = ($Request.Body.tenantFilter.addedFields.defaultDomainName)
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

$t5= @"
{
  "tenantFilter": [
    {
      "value": "598daf45-16f3-4fea-bfaf-a48666120d6c",
      "label": "Schjeldal (schjeldal.dk)",
      "type": "Tenant",
      "addedFields": {
        "defaultDomainName": "schjeldal.dk",
        "displayName": "Schjeldal",
        "customerId": "598daf45-16f3-4fea-bfaf-a48666120d6c"
      }
    }
  ],
  "TemplateList": {
    "label": "Ng.L1.P1: Win.Script.Platform.Create Laps admin",
    "value": "cdb506b6-5674-4e03-a0da-c87deb10a99e"
  },
  "RAWJson": "{\"@odata.context\":\"https://graph.microsoft.com/beta/$metadata#deviceManagement/deviceManagementScripts(assignments())/$entity\",\"enforceSignatureCheck\":false,\"runAs32Bit\":false,\"id\":\"cdb506b6-5674-4e03-a0da-c87deb10a99e\",\"displayName\":\"Ng.L1.P1: Win.Script.Platform.Create Laps admin\",\"description\":\"Create Laps admin: SupermuleLocal\",\"scriptContent\":\"IyBwYXJhbSgNCiMgICBbUGFyYW1ldGVyKE1hbmRhdG9yeT0kdHJ1ZSwgcG9zaXRpb249MSwgSGVscE1lc3NhZ2U9IkVudGVyIFVzZXJOYW1lIGZvciB0aGUgbmV3IGxvY2FsIGFkbWluaXN0cmF0b3IgYWNjb3VudCIpXQ0KIyAgIFtzdHJpbmddJFVzZXJOYW1lLA0KIyAgIFtQYXJhbWV0ZXIoTWFuZGF0b3J5PSRmYWxzZSwgcG9zaXRpb249MiwgSGVscE1lc3NhZ2U9IkVudGVyIERlc2NyaXB0aW9uIGZvciB0aGUgbmV3IGxvY2FsIGFkbWluaXN0cmF0b3IgYWNjb3VudCIpXQ0KIyAgIFtzdHJpbmddJERlc2NyaXB0aW9uID0gIk5nTVMgTEFQUyBBZG1pbmlzdHJhdG9yIg0KIyApDQoNCiRVc2VyTmFtZSA9ICJOZ0xvY2FsQWRtaW4iDQokRGVzY3JpcHRpb24gPSAiTmdNUyBMQVBTIEFkbWluaXN0cmF0b3IiDQoNCiR1c2VyZXhpc3QgPSAoR2V0LUxvY2FsVXNlcikuTmFtZSAtQ29udGFpbnMgJFVzZXJOYW1lDQppZigkdXNlcmV4aXN0IC1lcSAkZmFsc2UpIHsNCiAgdHJ5eyANCiAgICAgTmV3LUxvY2FsVXNlciAtTmFtZSAkVXNlck5hbWUgLURlc2NyaXB0aW9uICREZXNjcmlwdGlvbiAtTm9QYXNzd29yZCAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICBBZGQtTG9jYWxHcm91cE1lbWJlciAtU0lEICJTLTEtNS0zMi01NDQiIC1NZW1iZXIgJFVzZXJOYW1lDQogICB9ICAgDQogIENhdGNoIHsNCiAgICBpZiAoJF8uRXhjZXB0aW9uLk1lc3NhZ2UgLWVxICJBY2Nlc3MgZGVuaWVkLiIpew0KICAgICAgV3JpdGUtRXJyb3IgIkFjY2VzcyBkZW5pZWQuIFBsZWFzZSBydW4gdGhlIHNjcmlwdCBhcyBhbiBBZG1pbmlzdHJhdG9yLiINCiAgICAgIEV4aXQgMQ0KICAgIH0NCiAgICBlbHNlIHsNCiAgICAgIFdyaXRlLWVycm9yICRfDQogICAgICBFeGl0IDENCiAgICB9DQogICB9DQp9DQoNCmlmKCR1c2VyZXhpc3QgLWVxICR0cnVlKSB7DQogICAgaWYgKCEoKEdldC1Mb2NhbEdyb3VwTWVtYmVyIC1TSUQgIlMtMS01LTMyLTU0NCIpLk5hbWUgLW1hdGNoICJcXCRVc2VyTmFtZSQiKSl7DQogICAgICAgIHRyeXsgDQogICAgICAgICAgICBBZGQtTG9jYWxHcm91cE1lbWJlciAtU0lEICJTLTEtNS0zMi01NDQiIC1NZW1iZXIgJFVzZXJOYW1lDQogICAgICAgICAgfSAgIA0KICAgICAgICAgQ2F0Y2ggew0KICAgICAgICAgICAgV3JpdGUtZXJyb3IgJF8NCiAgICAgICAgICAgIEV4aXQgMQ0KICAgICAgICB9DQogICAgfQ0KICB9\",\"createdDateTime\":\"2025-03-27T00:13:50.8480567Z\",\"lastModifiedDateTime\":\"2025-03-27T00:49:34.2418831Z\",\"runAsAccount\":\"system\",\"fileName\":\"Create-LapsUser.ps1\",\"roleScopeTagIds\":[\"0\"],\"assignments@odata.context\":\"https://graph.microsoft.com/beta/$metadata#deviceManagement/deviceManagementScripts('cdb506b6-5674-4e03-a0da-c87deb10a99e')/assignments\",\"assignments\":[{\"id\":\"cdb506b6-5674-4e03-a0da-c87deb10a99e:adadadad-808e-44e2-905a-0b7873a8a531\",\"target\":{\"@odata.type\":\"#microsoft.graph.allDevicesAssignmentTarget\",\"deviceAndAppManagementAssignmentFilterId\":null,\"deviceAndAppManagementAssignmentFilterType\":\"none\"}}]}",
  "AssignTo": "AllDevices",
  "overwrite": false,
  "displayName": "Ng.L1.P1: Win.Script.Platform.Create Laps admin",
  "description": "Create Laps admin: SupermuleLocal",
  "TemplateType": "Windows"
}
"@ |ConvertFrom-Json
