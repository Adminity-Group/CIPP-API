using namespace System.Net

Function Invoke-EditTenant {
    <#
    .FUNCTIONALITY
        Entrypoint,AnyTenant
    .ROLE
        Tenant.Config.ReadWrite
    #>
    [CmdletBinding()]
    param($Request, $TriggerMetadata)

    $APIName = $Request.Params.CIPPEndpoint

    Write-LogMessage -headers $Request.Headers -API $APINAME -message 'Accessed this API' -Sev 'Debug'

    $customerId = $Request.Body.customerId
    $tenantAlias = $Request.Body.tenantAlias
    $tenantGroups = $Request.Body.tenantGroups

    #NgMS
    $tenantShortname = $Request.Body.tenantShortname

    $PropertiesTable = Get-CippTable -TableName 'TenantProperties'
    $Existing = Get-CIPPAzDataTableEntity @PropertiesTable -Filter "PartitionKey eq '$customerId'"
    $Tenant = Get-Tenants -TenantFilter $customerId
    $TenantTable = Get-CippTable -TableName 'Tenants'
    $GroupMembersTable = Get-CippTable -TableName 'TenantGroupMembers'

    try {

        if ($tenantShortname) {

            $regex = '^(?![0-9]+$)(?!.*\s)[a-zA-Z0-9-]{1,6}$'
            if ($tenantShortname -notmatch $regex) {
                Write-LogMessage -API $APINAME -tenant $customerId -headers $Request.Headers -message "Failed to set Tenant ShortName '$($tenantShortname)' for customer $customerId. Error: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space" -Sev 'Error'
                Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                    StatusCode = [HttpStatusCode]::BadRequest
                    Body       = 'Validation Failed: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space'
                })
                return
            }


            $ShortnameEntity = @{
                PartitionKey = $customerId
                RowKey       = 'Shortname'
                Value        = $tenantShortname
            }
            $null = Add-CIPPAzDataTableEntity @PropertiesTable -Entity $ShortnameEntity -Force
            Write-LogMessage -API $APINAME -tenant $customerId -headers $Request.Headers -message "Set Tenant ShortName '$($tenantShortname)' for customer $customerId" -Sev 'Info'

        }

        $AliasEntity = $Existing | Where-Object { $_.RowKey -eq 'Alias' }
        if (!$tenantAlias) {
            if ($AliasEntity) {
                Write-Host 'Removing alias'
                Remove-AzDataTableEntity @PropertiesTable -Entity $AliasEntity
                $null = Get-Tenants -TenantFilter $customerId -TriggerRefresh
            }
        } else {
            $aliasEntity = @{
                PartitionKey = $customerId
                RowKey       = 'Alias'
                Value        = $tenantAlias
            }
            $null = Add-CIPPAzDataTableEntity @PropertiesTable -Entity $aliasEntity -Force
            Write-Host "Setting alias to $tenantAlias"
            $Tenant.displayName = $tenantAlias
            $null = Add-CIPPAzDataTableEntity @TenantTable -Entity $Tenant -Force
        }

        # Update tenant groups
        $CurrentMembers = Get-CIPPAzDataTableEntity @GroupMembersTable -Filter "customerId eq '$customerId'"
        foreach ($Group in $tenantGroups) {
            $GroupEntity = $CurrentMembers | Where-Object { $_.GroupId -eq $Group.groupId }
            if (!$GroupEntity) {
                $GroupEntity = @{
                    PartitionKey = 'Member'
                    RowKey       = '{0}-{1}' -f $Group.groupId, $customerId
                    GroupId      = $Group.groupId
                    customerId   = $customerId
                }
                Add-CIPPAzDataTableEntity @GroupMembersTable -Entity $GroupEntity -Force
            }
        }

        # Remove any groups that are no longer selected
        foreach ($Group in $CurrentMembers) {
            if ($tenantGroups -notcontains $Group.GroupId) {
                Remove-AzDataTableEntity @GroupMembersTable -Entity $Group
            }
        }

        $response = @{
            state      = 'success'
            resultText = 'Tenant details updated successfully'
        }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK
                Body       = $response
            })
    } catch {
        Write-LogMessage -headers $Request.Headers -tenant $customerId -API $APINAME -message "Edit Tenant failed. The error is: $($_.Exception.Message)" -Sev 'Error'
        $response = @{
            state      = 'error'
            resultText = $_.Exception.Message
        }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::InternalServerError
                Body       = $response
            })
    }
}
