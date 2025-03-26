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

    $Tenants = ($Request.Body.tenantFilter.value)
    if ('AllTenants' -in $Tenants) { $Tenants = (Get-Tenants).defaultDomainName }
    $displayname = $Request.Body.displayName
    $description = $Request.Body.Description
    $AssignTo = if ($Request.Body.AssignTo -ne 'on') { $Request.Body.AssignTo }
    $ExcludeGroup = $Request.Body.excludeGroup
    $Request.body.customGroup ? ($AssignTo = $Request.body.customGroup) : $null
    $RawJSON = $Request.Body.RAWJson
    $Overwrite = $Request.Body.Overwrite
    $ScriptType = $Request.Body.TemplateType

    try {
        Write-host "Script: $($Request.Body | ConvertTo-Json -Depth 5)"

        $Results = foreach ($Tenant in $Tenants) {
            try {
                Write-Host 'Calling Adding Script'
                $null = Set-CIPPIntuneScript -tenantFilter $Tenant -RawJSON $RawJSON -Overwrite $Overwrite -APIName $APIName -Headers $Request.Headers -AssignTo $AssignTo -ExcludeGroup $ExcludeGroup -ScriptType $ScriptType -Displayname $Displayname -Description $description -errorAction Stop
                $Results += "Added Script $($Displayname) to tenant $($Tenant)"
                Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $Tenant -message "Added policy $($Displayname)" -Sev 'Info'
            } catch {
                $Results += "Failed to add script $($Displayname) to tenant $($Tenant). $($_.Exception.Message)"
                Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $Tenant -message "Failed to add script $($Displayname). Error: $($_.Exception.Message)" -Sev 'Error'
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
        Write-LogMessage -headers $Request.Headers -API $APINAME -tenant $Tenant -message "Failed to proccess request policy. Error: $($_.Exception.Message)" -Sev 'Error'
    }

}

$t = @"
{
  "Body": {
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
      "label": "test",
      "value": "34cfeaa8-c9d1-45a8-98ae-1190acc39205"
    },
    "RAWJson": "{\"@odata.context\":\"https://graph.microsoft.com/beta/$metadata#deviceManagement/deviceManagementScripts(assignments())/$entity\",\"enforceSignatureCheck\":false,\"runAs32Bit\":false,\"id\":\"423fb247-f985-4ba2-be31-c0ec12e6ff1f\",\"displayName\":\"test\",\"description\":\"\",\"scriptContent\":\"IyBwYXJhbSgNCiMgICBbUGFyYW1ldGVyKE1hbmRhdG9yeT0kdHJ1ZSwgcG9zaXRpb249MSwgSGVscE1lc3NhZ2U9IkVudGVyIFVzZXJOYW1lIGZvciB0aGUgbmV3IGxvY2FsIGFkbWluaXN0cmF0b3IgYWNjb3VudCIpXQ0KIyAgIFtzdHJpbmddJFVzZXJOYW1lLA0KIyAgIFtQYXJhbWV0ZXIoTWFuZGF0b3J5PSRmYWxzZSwgcG9zaXRpb249MiwgSGVscE1lc3NhZ2U9IkVudGVyIERlc2NyaXB0aW9uIGZvciB0aGUgbmV3IGxvY2FsIGFkbWluaXN0cmF0b3IgYWNjb3VudCIpXQ0KIyAgIFtzdHJpbmddJERlc2NyaXB0aW9uID0gIk5nTVMgTEFQUyBBZG1pbmlzdHJhdG9yIg0KIyApDQoNCiRVc2VyTmFtZSA9ICJOZ0xvY2FsQWRtaW4iDQokRGVzY3JpcHRpb24gPSAiTmdNUyBMQVBTIEFkbWluaXN0cmF0b3IiDQoNCiR1c2VyZXhpc3QgPSAoR2V0LUxvY2FsVXNlcikuTmFtZSAtQ29udGFpbnMgJFVzZXJOYW1lDQppZigkdXNlcmV4aXN0IC1lcSAkZmFsc2UpIHsNCiAgdHJ5eyANCiAgICAgTmV3LUxvY2FsVXNlciAtTmFtZSAkVXNlck5hbWUgLURlc2NyaXB0aW9uICREZXNjcmlwdGlvbiAtTm9QYXNzd29yZCAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICBBZGQtTG9jYWxHcm91cE1lbWJlciAtU0lEICJTLTEtNS0zMi01NDQiIC1NZW1iZXIgJFVzZXJOYW1lDQogICB9ICAgDQogIENhdGNoIHsNCiAgICBpZiAoJF8uRXhjZXB0aW9uLk1lc3NhZ2UgLWVxICJBY2Nlc3MgZGVuaWVkLiIpew0KICAgICAgV3JpdGUtRXJyb3IgIkFjY2VzcyBkZW5pZWQuIFBsZWFzZSBydW4gdGhlIHNjcmlwdCBhcyBhbiBBZG1pbmlzdHJhdG9yLiINCiAgICAgIEV4aXQgMQ0KICAgIH0NCiAgICBlbHNlIHsNCiAgICAgIFdyaXRlLWVycm9yICRfDQogICAgICBFeGl0IDENCiAgICB9DQogICB9DQp9DQoNCmlmKCR1c2VyZXhpc3QgLWVxICR0cnVlKSB7DQogICAgaWYgKCEoKEdldC1Mb2NhbEdyb3VwTWVtYmVyIC1TSUQgIlMtMS01LTMyLTU0NCIpLk5hbWUgLW1hdGNoICJcXCRVc2VyTmFtZSQiKSl7DQogICAgICAgIHRyeXsgDQogICAgICAgICAgICBBZGQtTG9jYWxHcm91cE1lbWJlciAtU0lEICJTLTEtNS0zMi01NDQiIC1NZW1iZXIgJFVzZXJOYW1lDQogICAgICAgICAgfSAgIA0KICAgICAgICAgQ2F0Y2ggew0KICAgICAgICAgICAgV3JpdGUtZXJyb3IgJF8NCiAgICAgICAgICAgIEV4aXQgMQ0KICAgICAgICB9DQogICAgfQ0KICB9\",\"createdDateTime\":\"2025-03-25T19:21:13.232406Z\",\"lastModifiedDateTime\":\"2025-03-25T19:21:13.232406Z\",\"runAsAccount\":\"system\",\"fileName\":\"Create-LapsUser.ps1\",\"roleScopeTagIds\":[\"0\"],\"assignments@odata.context\":\"https://graph.microsoft.com/beta/$metadata#deviceManagement/deviceManagementScripts('423fb247-f985-4ba2-be31-c0ec12e6ff1f')/assignments\",\"assignments\":[{\"id\":\"423fb247-f985-4ba2-be31-c0ec12e6ff1f:adadadad-808e-44e2-905a-0b7873a8a531\",\"target\":{\"@odata.type\":\"#microsoft.graph.allDevicesAssignmentTarget\",\"deviceAndAppManagementAssignmentFilterId\":null,\"deviceAndAppManagementAssignmentFilterType\":\"none\"}}]}",
    "AssignTo": "On",
    "overwrite": false,
    "displayName": "test",
    "description": "",
    "TemplateType": "Windows"
  },
  "Headers": {
    "accept": "application/json, text/plain, */*",
    "accept-language": "en-US,en;q=0.9,da;q=0.8",
    "content-length": "2989",
    "content-type": "application/json",
    "cookie": "_ga=GA1.1.1305313826.1731349213; wfx_unq=D8w6bboPH5xRTywW; _ga_9R3P44QPKQ=GS1.1.1738582831.23.1.1738582901.0.0.0; AppServiceAuthSession=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; AppServiceAuthSession1=8xaJGbIhUWKy5iMm8dD30I4R6ccvJi8TKbwmL5APmSWh80PyUE+yWHvNgJcbRxRBEWjGI8p0zys4IR1b8DcQ54MrLt0vtouC5xcckm5AdCjN2AuU5vs/o2I726wW1KpvLHuRdnjvBJPVTrFyiVQgGPWNHd9CfO4Fbv3hMPvJrK825pJDX2Rmd8/BIAAwZCro1eh+H1GNYVSNQ7Ydx99wL5TpMJ2wwGJXbIuiOoJnkm7792C5Ze/WY2NOe1yZBG31dvZyvz5ZAp8O+vPfz1tTyX7KmrOBsVggSMiTR8zllQKuSEfO6dIi1O154ArCYwKVMfOngNJ8+TfIyZHvEZDDtnjuzzF9/nE2qaE0vMjMcO4CIcTEOvMrEZ31OeMyREy3X2tY+GIbVyzlQp5a/hpG3ilQMgme8MxwLP5jUaZmkucxhtLZNDGvUB48xr60C82HzTJ50yHd1c8MkXF0NwGhcYLj+RQpmFMx9cjws50HDTzftV1/givmLN+nXaSWPyFxYi816DCx7ULjUopsMTtd5rbJbMD5q48pP3yFAr2n/iT3kz9ptYII7YemUb21HFma64mfOks8lCj09WQKnyKYjWK4Carp2zDCyo8E4EKIU7nrRNpG7nheWDeen2O6xjalSAdzurwNksEGRzuZJweF2J5EFwT42kinH9DrbG0WDvk68hxYkB3AeKMIxABNEkjb3XVTBPkps1j0JD4B85sbj3+W0T3C/PRrNoniJO8XGBmvWwrw090My8DJebs85U+BIm6Q5VWle+p3WI0+p6jUjjs60OCAYfI6LtylJrHuJIClUlxihazEUmJnizGqqBCMugRjmg1nA58T69GKENU9Qfo2m2LqlGmcbVOqaRcHiBgMFlfI+xpjz4qFbXR7fMTqbSm/mmiFs7hdV8aRsfmXtwapSEvYHmwVCcKuh4LB+O9m1XCpbH48ZdKyqFEajuIzzzohXW6ujUNXxK2hNzhNF+7/OdnFwD+MxjjAw2F7Qwu6AzzJFH2kU8Qlfkv+P3XMPblkw2lbgFX5cY4aUe1ftwc6M7wmrGGngVyJa3oWJAffJ4T1fRs5O2JbHBw2LjyYOlxfGMdx+1vj70Hb4B5NkqIcwnFRcrk8Pih7Sx4QLjiL8bCPPWR4o4SN3odirALCRo583hDUwZpY7rpZiJz2RZPufpBG8QkKzD5HvFby9SgZtF8NHY1LnfTMfAEmBHpCTHFLumtx8eiZQKCQVreKVABQzBLfGrM26PfiHYaHfZAdhyTjNrlbzyFYXnSKjsE8mh9D1Sz49ikgdFlbZlqIrEEJKxt0rj+5I9t4NlAYhabeC0A6RWyTIUBZ261z8vsophIE2nKLLL42QtnGqAzhdGrMKTxG6iTfcXCc95sdBJ9x0R7L3Mcmng4ODfNsPBzzsh25yMxoxhqolBwY0YYnj+6/npp9suEgesSPiRIOPKuQlX+X0hDO93zHpmUr5gmm7NlLYlGLc55BoCX19f4fmjer5dHM54DsCfl8bHsm5+LhnlFE2632CzAVmmotb+1EU37uQ1WBjyhzObkmp4M4qpqcoF8yy3nws32hE4Jso7uzcBMbAZ5n0GM9CVOib5UIztU1XQ==; StaticWebAppsAuthCookie=k6UTgszDRNi+J9z3xuJNSFs0vrIGZqftqm/l6+HM/lxhNq/3n8Ct5KTNNwQEEzBFk8QHT5ATbd/0yZTZdKLKoRShCCtgEofQfFrPMulGsw0OHsJWSDxtW5sNDVpuwHj0oy1sFwfsOO7CbP2YvZoeMxycrJ4tLSmpE96TcSOgfBAQva2WcuK2ESj8abj9H6jFNxNBsDjxm7xjCJYnPLwn/iY5u1fmx8xOCOPfwQLc4iePoqblfBlfypWWCD0P2TH36sO2Dk7RgSQw2AxuWJxvjqTIiamZkxnqtktwlT9sXDQ=",
    "host": "cippkfzw2.azurewebsites.net",
    "max-forwards": "8",
    "referer": "https://cipp.ngms.dk/endpoint/MEM/list-scripts/deploy",
    "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36 Edg/134.0.0.0",
    "origin": "https://cipp.ngms.dk",
    "traceparent": "00-ecc5083c2f571ece996e6b75659abaa1-d2c8783246bc4d4d-00",
    "sec-ch-ua-platform": "\"Windows\"",
    "sec-ch-ua": "\"Chromium\";v=\"134\", \"Not:A-Brand\";v=\"24\", \"Microsoft Edge\";v=\"134\"",
    "sec-ch-ua-mobile": "?0",
    "sec-fetch-site": "same-origin",
    "sec-fetch-mode": "cors",
    "sec-fetch-dest": "empty",
    "priority": "u=1, i",
    "x-arr-log-id": "8720c19e-7c3c-4c68-8b07-e068559b5d20",
    "client-ip": "10.0.32.22:28828",
    "x-site-deployment-id": "cippkfzw2",
    "was-default-hostname": "cippkfzw2.azurewebsites.net",
    "x-forwarded-proto": "https",
    "x-appservice-proto": "https",
    "x-arr-ssl": "2048|256|CN=Microsoft Azure RSA TLS Issuing CA 04, O=Microsoft Corporation, C=US|CN=*.azurewebsites.net, O=Microsoft Corporation, L=Redmond, S=WA, C=US",
    "x-forwarded-tlsversion": "1.3",
    "x-forwarded-for": "93.165.250.148:37627, 13.69.64.134:22020",
    "x-original-url": "/api/AddScript",
    "x-waws-unencoded-url": "/api/AddScript",
    "x-ms-original-url": "https://cipp.ngms.dk/api/AddScript",
    "x-ms-request-id": "8720c19e-7c3c-4c68-8b07-e068559b5d20",
    "x-ms-auth-token": "Bearer eyJhbGciOiJSUzI1NiIsImtpZCI6IkQ5M0NDNUE1QkYyOUMwODkyRjMwOEQ3MDc3NUIzQUQ0OENGNDc5MTMiLCJ0eXAiOiJKV1QifQ.eyJwcm4iOiJleUpwWkdWdWRHbDBlVkJ5YjNacFpHVnlJam9pWVdGa0lpd2lkWE5sY2tsa0lqb2lOREF5WldVeU5qUXRNREkyWlMwME9UaGpMVGxsTURjdE1qSXhOV1U1TUdJeVpqazJJaXdpZFhObGNrUmxkR0ZwYkhNaU9pSndjMmhBYm1kdGN5NWtheUlzSW5WelpYSlNiMnhsY3lJNld5SmhaRzFwYmlJc0ltRnViMjU1Ylc5MWN5SXNJbUYxZEdobGJuUnBZMkYwWldRaVhYMD0iLCJzdWIiOiI0MDJlZTI2NC0wMjZlLTQ5OGMtOWUwNy0yMjE1ZTkwYjJmOTYiLCJpc3MiOiJodHRwczovL21hbmdvLW1vc3MtMDI3MjUzYzAzLjUuYXp1cmVzdGF0aWNhcHBzLm5ldC8uYXV0aCIsImF1ZCI6Imh0dHBzOi8vY2lwcGtmencyLmF6dXJld2Vic2l0ZXMubmV0IiwibmJmIjoxNzQzMDE5NDQzLCJleHAiOjE3NDMwMTk3NDMsImlhdCI6MTc0MzAxOTQ0M30.bnCm1lp7lTpljAp9uN9QzRVSlUcjlSV6NZ-tsk-Jpf6yWl3dykYhNqAZduhoiAz2XzZgJ1oneK_zeZgWrafnfu2OCktsYG6kzCzIISVlPvxhIsn1OmcMGGHQjImhhKPRffpMGDq-5v0xZKi2BLJAnI0ckDhbZ-vFHYDJ5PcKZWACXO0cRoJFm_MISkBoo4BWbdBfMaabMbjIB7CQZLK6ztEvE75YMxsPJwlOWbipHpU26IN1UrQ3Zend7F-_WKXlYplZR3NLZNfTE3OcXdPSR5G4pov336Was28FucZxti4Kq5o-QzaJzygbttdNG7XRU-8IrIdQtmKWVlJsRfB0EQ",
    "disguised-host": "cippkfzw2.azurewebsites.net",
    "x-ms-client-principal-name": "psh@ngms.dk",
    "x-ms-client-principal-id": "402ee264-026e-498c-9e07-2215e90b2f96",
    "x-ms-client-principal-idp": "azureStaticWebApps",
    "x-ms-client-principal": "eyJpZGVudGl0eVByb3ZpZGVyIjoiYWFkIiwidXNlcklkIjoiNDAyZWUyNjQtMDI2ZS00OThjLTllMDctMjIxNWU5MGIyZjk2IiwidXNlckRldGFpbHMiOiJwc2hAbmdtcy5kayIsInVzZXJSb2xlcyI6WyJhZG1pbiIsImFub255bW91cyIsImF1dGhlbnRpY2F0ZWQiXX0="
  },
  "Method": "POST",
  "Url": "https://cippkfzw2.azurewebsites.net/api/AddScript",
  "Params": {
    "CIPPEndpoint": "AddScript"
  },
  "Query": {},
  "RawBody": "{\"tenantFilter\":[{\"value\":\"598daf45-16f3-4fea-bfaf-a48666120d6c\",\"label\":\"Schjeldal (schjeldal.dk)\",\"type\":\"Tenant\",\"addedFields\":{\"defaultDomainName\":\"schjeldal.dk\",\"displayName\":\"Schjeldal\",\"customerId\":\"598daf45-16f3-4fea-bfaf-a48666120d6c\"}}],\"TemplateList\":{\"label\":\"test\",\"value\":\"34cfeaa8-c9d1-45a8-98ae-1190acc39205\"},\"RAWJson\":\"{\\\"@odata.context\\\":\\\"https://graph.microsoft.com/beta/$metadata#deviceManagement/deviceManagementScripts(assignments())/$entity\\\",\\\"enforceSignatureCheck\\\":false,\\\"runAs32Bit\\\":false,\\\"id\\\":\\\"423fb247-f985-4ba2-be31-c0ec12e6ff1f\\\",\\\"displayName\\\":\\\"test\\\",\\\"description\\\":\\\"\\\",\\\"scriptContent\\\":\\\"IyBwYXJhbSgNCiMgICBbUGFyYW1ldGVyKE1hbmRhdG9yeT0kdHJ1ZSwgcG9zaXRpb249MSwgSGVscE1lc3NhZ2U9IkVudGVyIFVzZXJOYW1lIGZvciB0aGUgbmV3IGxvY2FsIGFkbWluaXN0cmF0b3IgYWNjb3VudCIpXQ0KIyAgIFtzdHJpbmddJFVzZXJOYW1lLA0KIyAgIFtQYXJhbWV0ZXIoTWFuZGF0b3J5PSRmYWxzZSwgcG9zaXRpb249MiwgSGVscE1lc3NhZ2U9IkVudGVyIERlc2NyaXB0aW9uIGZvciB0aGUgbmV3IGxvY2FsIGFkbWluaXN0cmF0b3IgYWNjb3VudCIpXQ0KIyAgIFtzdHJpbmddJERlc2NyaXB0aW9uID0gIk5nTVMgTEFQUyBBZG1pbmlzdHJhdG9yIg0KIyApDQoNCiRVc2VyTmFtZSA9ICJOZ0xvY2FsQWRtaW4iDQokRGVzY3JpcHRpb24gPSAiTmdNUyBMQVBTIEFkbWluaXN0cmF0b3IiDQoNCiR1c2VyZXhpc3QgPSAoR2V0LUxvY2FsVXNlcikuTmFtZSAtQ29udGFpbnMgJFVzZXJOYW1lDQppZigkdXNlcmV4aXN0IC1lcSAkZmFsc2UpIHsNCiAgdHJ5eyANCiAgICAgTmV3LUxvY2FsVXNlciAtTmFtZSAkVXNlck5hbWUgLURlc2NyaXB0aW9uICREZXNjcmlwdGlvbiAtTm9QYXNzd29yZCAtRXJyb3JBY3Rpb24gU3RvcA0KICAgICBBZGQtTG9jYWxHcm91cE1lbWJlciAtU0lEICJTLTEtNS0zMi01NDQiIC1NZW1iZXIgJFVzZXJOYW1lDQogICB9ICAgDQogIENhdGNoIHsNCiAgICBpZiAoJF8uRXhjZXB0aW9uLk1lc3NhZ2UgLWVxICJBY2Nlc3MgZGVuaWVkLiIpew0KICAgICAgV3JpdGUtRXJyb3IgIkFjY2VzcyBkZW5pZWQuIFBsZWFzZSBydW4gdGhlIHNjcmlwdCBhcyBhbiBBZG1pbmlzdHJhdG9yLiINCiAgICAgIEV4aXQgMQ0KICAgIH0NCiAgICBlbHNlIHsNCiAgICAgIFdyaXRlLWVycm9yICRfDQogICAgICBFeGl0IDENCiAgICB9DQogICB9DQp9DQoNCmlmKCR1c2VyZXhpc3QgLWVxICR0cnVlKSB7DQogICAgaWYgKCEoKEdldC1Mb2NhbEdyb3VwTWVtYmVyIC1TSUQgIlMtMS01LTMyLTU0NCIpLk5hbWUgLW1hdGNoICJcXCRVc2VyTmFtZSQiKSl7DQogICAgICAgIHRyeXsgDQogICAgICAgICAgICBBZGQtTG9jYWxHcm91cE1lbWJlciAtU0lEICJTLTEtNS0zMi01NDQiIC1NZW1iZXIgJFVzZXJOYW1lDQogICAgICAgICAgfSAgIA0KICAgICAgICAgQ2F0Y2ggew0KICAgICAgICAgICAgV3JpdGUtZXJyb3IgJF8NCiAgICAgICAgICAgIEV4aXQgMQ0KICAgICAgICB9DQogICAgfQ0KICB9\\\",\\\"createdDateTime\\\":\\\"2025-03-25T19:21:13.232406Z\\\",\\\"lastModifiedDateTime\\\":\\\"2025-03-25T19:21:13.232406Z\\\",\\\"runAsAccount\\\":\\\"system\\\",\\\"fileName\\\":\\\"Create-LapsUser.ps1\\\",\\\"roleScopeTagIds\\\":[\\\"0\\\"],\\\"assignments@odata.context\\\":\\\"https://graph.microsoft.com/beta/$metadata#deviceManagement/deviceManagementScripts('423fb247-f985-4ba2-be31-c0ec12e6ff1f')/assignments\\\",\\\"assignments\\\":[{\\\"id\\\":\\\"423fb247-f985-4ba2-be31-c0ec12e6ff1f:adadadad-808e-44e2-905a-0b7873a8a531\\\",\\\"target\\\":{\\\"@odata.type\\\":\\\"#microsoft.graph.allDevicesAssignmentTarget\\\",\\\"deviceAndAppManagementAssignmentFilterId\\\":null,\\\"deviceAndAppManagementAssignmentFilterType\\\":\\\"none\\\"}}]}\",\"AssignTo\":\"On\",\"overwrite\":false,\"displayName\":\"test\",\"description\":\"\",\"TemplateType\":\"Windows\"}"
}
"@ |ConvertFrom-Json
