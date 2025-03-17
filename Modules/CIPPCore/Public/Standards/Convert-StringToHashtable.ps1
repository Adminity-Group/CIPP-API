function Convert-StringToHashtable {
    param (
        [string]$InputString
    )
    try {
        # Remove square brackets and split into lines
        $InputString = $InputString.Trim('[', ']')
        $hashtable = @{}
        $InputString -split "`n" | ForEach-Object {
            $key, $value = $_ -split ":\s*"
            $hashtable[$key.Trim()] = [System.Convert]::ToBoolean($value.Trim())
        }
        return $hashtable
    }
    catch {
        Write-LogMessage -API 'Standards' -tenant $Tenant -message "Convert-StringToHashtable: Failed to convert string to hashtable" -sev Error -LogData $_
    }

}
