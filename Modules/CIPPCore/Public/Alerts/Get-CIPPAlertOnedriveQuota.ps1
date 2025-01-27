function Get-CIPPAlertOneDriveQuota {
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
        $Tenant = Get-Tenants -TenantFilter $TenantFilter
        $TenantId = $Tenant.customerId

        $Usage = New-GraphGetRequest -tenantid $TenantId -uri "https://graph.microsoft.com/beta/reports/getOneDriveUsageAccountDetail(period='D7')?`$format=application/json&`$top=999" -AsApp $true
        if (!$Usage) {
            Write-AlertMessage -tenant $($TenantFilter) -message "OneDrive quota Alert: Unable to get OneDrive usage: Error occurred: $(Get-NormalizedError -message $_.Exception.message)"
            return
        }
    }
    catch {
        return
    }
    
    #Alert threshold value for OneDrive quota
    try {
        if ([int]$InputValue -gt 0) { $Value = [int]$InputValue } else { $Value = 90 }
    } catch {
        $Value = 90
    }

    #Check if the OneDrive quota is over the threshold
    $OverQuota = $Usage | Where-Object { ($_.storageUsedInBytes / $_.storageAllocatedInBytes) * 100 -gt $Value }

    #If the quota is over the threshold, send an alert
    if ($OverQuota) {
        $Output = $OverQuota | ForEach-Object {
            "$($_.ownerPrincipalName): OneDrive is $([math]::Round(($_.storageUsedInBytes / $_.storageAllocatedInBytes) * 100))% full. OneDrive has $([math]::Round(($_.storageAllocatedInBytes - $_.storageUsedInBytes) / 1GB))GB storage left"
        }
        Write-AlertTrace -cmdletName $MyInvocation.MyCommand -tenantFilter $TenantFilter -data $Output
    }
}
