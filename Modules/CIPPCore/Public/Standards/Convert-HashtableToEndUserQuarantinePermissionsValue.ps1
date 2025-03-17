function Convert-HashtableToEndUserQuarantinePermissionsValue {
    param (
        [hashtable]$InputHashtable
    )
    try {
        $EndUserQuarantinePermissionsValue = 0
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToViewHeader * 128
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToDownload * 64
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToAllowSender * 32
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToBlockSender * 16
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToRequestRelease * 8
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToRelease * 4
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToPreview * 2
        $EndUserQuarantinePermissionsValue += [int]$InputHashtable.PermissionToDelete * 1
        return $EndUserQuarantinePermissionsValue
    }
    catch {
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "Convert-HashtableToEndUserQuarantinePermissionsValue: Failed to hashtable QuarantinePermissionsValue" -sev Error -LogData $_
    }

}
