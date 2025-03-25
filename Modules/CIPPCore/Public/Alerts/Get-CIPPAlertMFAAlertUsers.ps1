function Get-CIPPAlertMFAAlertUsers {
    <#
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $false)]
        [Alias('input')]
        $InputValue,
        $TenantFilter
    )
    try {

        $users = New-GraphGETRequest -uri "https://graph.microsoft.com/beta/reports/authenticationMethods/userRegistrationDetails?`$top=999&filter=IsAdmin eq false and isMfaRegistered eq false and userType eq 'member'&`$select=userPrincipalName,lastUpdatedDateTime,isMfaRegistered,IsAdmin" -tenantid $($TenantFilter) | Where-Object { $_.userDisplayName -ne 'On-Premises Directory Synchronization Service Account' }
        if ($users.UserPrincipalName) {
            if ($InputValue){
                $DisabledUsers = New-GraphGETRequest -uri "https://graph.microsoft.com/beta/users?`$top=999&filter=accountEnabled eq false&`$select=id,userPrincipalName,accountEnabled" -tenantid $($TenantFilter)
                $Results = $users.UserPrincipalName | Where-Object { $_ -notin $DisabledUsers.UserPrincipalName }
            }
            else {
                $Results = $users.UserPrincipalName
            }
            $AlertData = "The following $($Results.Count) users do not have MFA registered: $($Results -join ', ')"
            Write-AlertTrace -cmdletName $MyInvocation.MyCommand -tenantFilter $TenantFilter -data $AlertData

        }

    } catch {
        Write-LogMessage -message "Failed to check MFA status for all users: $($_.exception.message)" -API 'MFA Alerts - Informational' -tenant $TenantFilter -sev Info
    }

}
