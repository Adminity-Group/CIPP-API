function Get-CIPPAlertAdminPassword {
    <#
    .FUNCTIONALITY
        Entrypoint
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [Alias('input')]
        $InputValue,
        $TenantFilter
    )
    try {
        # Get privileged role IDs
        $PrivilegedRoles = $DirectoryRoles | Where-Object {
            $_.DisplayName -like "*Administrator*" -or $_.DisplayName -eq "Global Reader"
        }

        # Get the members of these various roles
        $RoleMembers = $PrivilegedRoles | ForEach-Object { Get-MgDirectoryRoleMember -DirectoryRoleId $_.Id } |
            Select-Object Id -Unique

        # Retrieve details about the members in these roles
        $PrivilegedUsers = $RoleMembers | ForEach-Object {
            Get-MgUser -UserId $_.Id -Property UserPrincipalName, DisplayName, Id, OnPremisesSyncEnabled
        }

        $PrivilegedUsers | Where-Object { $_.OnPremisesSyncEnabled -eq $true } | ft DisplayName,UserPrincipalName,OnPremisesSyncEnabled

        Write-AlertTrace -cmdletName $MyInvocation.MyCommand -tenantFilter $TenantFilter -data $AlertData
    } catch {
        Write-AlertMessage -tenant $($TenantFilter) -message "Could not get admin password changes for $($TenantFilter): $(Get-NormalizedError -message $_.Exception.message)"
    }
}



