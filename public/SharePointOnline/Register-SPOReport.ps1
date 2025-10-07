<# SharePoint Tenant section #>
function Get-SPOTenantReport {
    param(
        [System.Boolean]$DisableAddToOneDrive
    )
    Write-Host "Checking tenant settings"
    if ($DisableAddToOneDrive) {
        Write-Host "Disable add to OneDrive button"
        Set-PnPTenant -DisableAddToOneDrive $True
    }
    $TenantData = Get-PnPTenant | Select-Object LegacyAuthProtocolsEnabled, DisableAddToOneDrive, ConditionalAccessPolicy, SharingCapability, RequireAcceptingAccountMatchInvitedAccount, PreventExternalUsersFromResharing, DefaultSharingLinkType
    Add-TenantReportSection -Category 'SharePoint Online' -Name 'Tenant settings' -Data $TenantData
    $Report = $TenantData | ConvertTo-Html -As List -Property LegacyAuthProtocolsEnabled, DisableAddToOneDrive, ConditionalAccessPolicy, SharingCapability, RequireAcceptingAccountMatchInvitedAccount, PreventExternalUsersFromResharing, DefaultSharingLinkType -Fragment -PreContent "<h3 id='SPO_SETTINGS'>Tenant settings</h3>" -PostContent "<p>ConditionalAccessPolicy: AllowFullAccess, AllowLimitedAccess, BlockAccess</p>
<p>SharingCapability: Disabled, ExternalUserSharingOnly, ExternalUserAndGuestSharing, ExistingExternalUserSharingOnly</p>
<p>DefaultSharingLinkType: None, Direct, Internal, AnonymousAccess</p>"
    $Report = $Report -Replace "<td>RequireAcceptingAccountMatchInvitedAccount:</td><td>False</td>", "<td>RequireAcceptingAccountMatchInvitedAccount:</td><td class='red'>False</td>"
    $Report = $Report -Replace "<td>LegacyAuthProtocolsEnabled:</td><td>True</td>", "<td>LegacyAuthProtocolsEnabled:</td><td class='red'>True</td>"
    $Report = $Report -Replace "<td>DisableAddToOneDrive:</td><td>False</td>", "<td>DisableAddToOneDrive:</td><td class='red'>False</td>"
    # $Report = $Report -Replace "<td>DisplayStartASiteOption:</td><td>True</td>", "<td>DisplayStartASiteOption:</td><td class='red'>True</td>"
    $Report = $Report -Replace "<td>ConditionalAccessPolicy:</td><td>AllowFullAccess</td>", "<td>ConditionalAccessPolicy:</td><td class='red'>AllowFullAccess</td>"
    $Report = $Report -Replace "<td>SharingCapability:</td><td>ExternalUserAndGuestSharing</td>", "<td>SharingCapability:</td><td class='red'>ExternalUserAndGuestSharing</td>"
    $Report = $Report -Replace "<td>PreventExternalUsersFromResharing:</td><td>False</td>", "<td>PreventExternalUsersFromResharing:</td><td class='red'>False</td>"
    $Report = $Report -Replace "<td>DefaultSharingLinkType:</td><td>AnonymousAccess</td>", "<td>DefaultSharingLinkType:</td><td class='red'>AnonymousAccess</td>"
    return $Report
}

function Get-SharePointAndOneDriveSites {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, HelpMessage = 'Provide the level of detail')]
        [ValidateSet('minimum', 'combined', 'all', 'geek')]
        [string]$DetailLevel,

        [Parameter(Mandatory, HelpMessage = 'Provide the service name')]
        [ValidateSet('MGGraph', 'SPO', 'API')]
        [string]$ServiceName
    )

    if ($ServiceName -ne 'SPO') {
        Write-Warning "Service '$ServiceName' is not currently supported. Falling back to SharePoint Online cmdlets."
    }

    Write-Host "Checking SharePoint Online and OneDrive sites ($DetailLevel detail)"

    try {
        switch ($DetailLevel) {
            'geek' {
                $sites = Get-SPOSite -IncludePersonalSite $true -Limit All
            }
            default {
                $desiredProperties = @(
                    'Template', 'IsHubSite', 'Title', 'LastContentModifiedDate', 'Status', 'ArchiveStatus',
                    'StorageUsageCurrent', 'LockState', 'Url', 'Owner', 'StorageQuota', 'GroupId',
                    'IsTeamsConnected', 'IsTeamsChannelConnected'
                )

                $sites = Get-SPOSite -IncludePersonalSite $true -Limit All | Select-Object -Property $desiredProperties
            }
        }
    }
    catch {
        Write-Warning "Unable to retrieve SharePoint sites. $_"
        Add-TenantReportStatus -Category 'SharePoint Online' -Name 'SharePoint sites' -Message 'Error retrieving site data'
        Add-TenantReportStatus -Category 'SharePoint Online' -Name 'OneDrive sites' -Message 'Error retrieving site data'
        return @(
            "<br><h3 id='SPO_SITES'>SharePoint sites</h3><p>Error retrieving site data</p>",
            "<br><h3 id='SPO_ONEDRIVE'>OneDrive sites</h3><p>Error retrieving site data</p>"
        )
    }

    if (-not $sites) {
        Add-TenantReportStatus -Category 'SharePoint Online' -Name 'SharePoint sites'
        Add-TenantReportStatus -Category 'SharePoint Online' -Name 'OneDrive sites'
        return @(
            "<br><h3 id='SPO_SITES'>SharePoint sites</h3><p>Not found</p>",
            "<br><h3 id='SPO_ONEDRIVE'>OneDrive sites</h3><p>Not found</p>"
        )
    }

    $siteRows = foreach ($site in $sites) {
        $isOneDrive = ($site.Url -like '*-my.sharepoint.com*')
        $storageUsedGb = if ($site.PSObject.Properties.Match('StorageUsageCurrent')) { [math]::Round(($site.StorageUsageCurrent / 1024), 3) } else { $null }
        $storageQuotaGb = if ($site.PSObject.Properties.Match('StorageQuota') -and $site.StorageQuota) { [math]::Round(($site.StorageQuota / 1024), 3) } else { $null }

        [pscustomobject]@{
            Title                     = $site.Title
            Url                       = $site.Url
            Owner                     = $site.Owner
            Template                  = $site.Template
            Status                    = $site.Status
            ArchiveStatus             = $site.ArchiveStatus
            IsHubSite                 = $site.IsHubSite
            LastContentModifiedDate   = $site.LastContentModifiedDate
            LockState                 = $site.LockState
            StorageUsageCurrentMB     = $site.StorageUsageCurrent
            StorageQuotaMB            = $site.StorageQuota
            StorageUsedGB             = $storageUsedGb
            StorageQuotaGB            = $storageQuotaGb
            GroupId                   = $site.GroupId
            IsTeamsConnected          = $site.IsTeamsConnected
            IsTeamsChannelConnected   = $site.IsTeamsChannelConnected
            IsOneDrive                = $isOneDrive
            DetailLevel               = $DetailLevel
        }
    }

    $sharePointSites = $siteRows | Where-Object { -not $_.IsOneDrive }
    $oneDriveSites = $siteRows | Where-Object { $_.IsOneDrive }

    if ($sharePointSites) {
        Add-TenantReportSection -Category 'SharePoint Online' -Name 'SharePoint sites' -Data $sharePointSites
    }
    else {
        Add-TenantReportStatus -Category 'SharePoint Online' -Name 'SharePoint sites'
    }

    if ($oneDriveSites) {
        Add-TenantReportSection -Category 'SharePoint Online' -Name 'OneDrive sites' -Data $oneDriveSites
    }
    else {
        Add-TenantReportStatus -Category 'SharePoint Online' -Name 'OneDrive sites'
    }

    $sharePointHtml = if ($sharePointSites) {
        $sharePointSites | Select-Object Title, Url, Owner, Template, StorageUsedGB, IsTeamsConnected |
            ConvertTo-Html -As Table -Property Title, Url, Owner, Template, StorageUsedGB, IsTeamsConnected `
                -Fragment -PreContent "<br><h3 id='SPO_SITES'>SharePoint sites</h3>"
    }
    else {
        "<br><h3 id='SPO_SITES'>SharePoint sites</h3><p>Not found</p>"
    }

    $oneDriveHtml = if ($oneDriveSites) {
        $oneDriveSites | Select-Object Title, Url, Owner, StorageUsedGB, LastContentModifiedDate |
            ConvertTo-Html -As Table -Property Title, Url, Owner, StorageUsedGB, LastContentModifiedDate `
                -Fragment -PreContent "<br><h3 id='SPO_ONEDRIVE'>OneDrive sites</h3>"
    }
    else {
        "<br><h3 id='SPO_ONEDRIVE'>OneDrive sites</h3><p>Not found</p>"
    }

    return @($sharePointHtml, $oneDriveHtml)
}
