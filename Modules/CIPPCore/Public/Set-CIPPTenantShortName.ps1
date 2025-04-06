Function Set-CIPPTenantShortName {
    <#
    .FUNCTIONALITY
        Entrypoint
    .ROLE
        CIPP.AppSettings.ReadWrite
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $Shortname,
        [Parameter(Mandatory = $true)]
        $customerId,
        $APIName = $APIName,
        $Headers
    )

    if ([string]::IsNullOrWhiteSpace($Shortname)) { $Shortname = $null }
    if (!$Shortname){
        throw "Shortname is required"
    }

    $regex = '^(?![0-9]+$)(?!.*\s)[a-zA-Z0-9-]{1,6}$'

    if ($Shortname -notmatch $regex) {
        Write-LogMessage -API $APIName -tenant $customerId -headers $Headers -message "Failed to set Tenant ShortName '$($Shortname)' for customer $customerId. Error: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space" -Sev 'Error'
        throw 'Validation Failed: ShortName must be 6 characters or less, and can contain letters (a-z, A-Z), numbers (0-9), and hyphens. Names must not contain only numbers. Names cannot include a blank space'
    }

    try {
        $Table = Get-CippTable -tablename 'TenantProperties'

        $VariableName = "Shortname"
        $VariableValue = $Shortname
        $VariableEntity = @{
            PartitionKey = $customerId
            RowKey       = $VariableName
            Value        = $VariableValue
        }

        $null = Add-CIPPAzDataTableEntity @Table -Entity $VariableEntity -Force

        Write-LogMessage -API $APIName -tenant $customerId -headers $Headers -message "Set Tenant ShortName '$($Shortname)' for customer $customerId" -Sev 'Info'
        Return "Success. We've added ShortName to $customerId."

        # Associate values to output bindings by calling 'Push-OutputBinding'
    }
    catch {
        Write-LogMessage -API $APIName -tenant $customerId -headers $Headers -message "Failed to set Tenant ShortName '$($Shortname)' for customer $customerId" -Sev 'Error'
        throw "$($_.Exception.Message)"
        # Associate values to output bindings by calling 'Push-OutputBinding'.
    }
}
