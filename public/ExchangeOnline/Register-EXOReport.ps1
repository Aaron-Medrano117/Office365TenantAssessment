function Join-ReportValue {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        $Value,

        [string]$Separator = ', '
    )

    begin {
        $items = New-Object System.Collections.Generic.List[string]
    }

    process {
        foreach ($entry in @($Value)) {
            if ($null -eq $entry) {
                continue
            }

            $text = $entry.ToString().Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $null = $items.Add($text)
            }
        }
    }

    end {
        if ($items.Count -eq 0) {
            return $null
        }

        return ($items.ToArray()) -join $Separator
    }
}

function Get-ExchangeRecipientDataset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('minimum', 'combined', 'all', 'geek')]
        [string]$DetailLevel
    )

    if ($script:ExchangeRecipientCache -and $script:ExchangeRecipientCacheDetailLevel -eq $DetailLevel) {
        return $script:ExchangeRecipientCache
    }

    $filter = "RecipientTypeDetails -ne 'DiscoveryMailbox' -and RecipientTypeDetails -ne 'MailContact' -and RecipientTypeDetails -ne 'GuestMailUser' -and RecipientTypeDetails -ne 'MailUser'"

    switch ($DetailLevel) {
        'geek' {
            $recipients = Get-EXORecipient -PropertySets All -ResultSize Unlimited -Filter $filter -ErrorAction Stop
        }
        default {
            $properties = @(
                'ExternalDirectoryObjectId', 'DisplayName', 'Identity', 'RecipientTypeDetails', 'PrimarySMTPAddress',
                'EmailAddresses', 'HiddenFromAddressListsEnabled', 'AddressBookPolicy',
                'ManagedBy', 'SKUAssigned', 'WhenCreated', 'WhenSoftDeleted', 'Guid',
                'Alias', 'Notes'
            )

            $recipients = Get-EXORecipient -Properties $properties -ResultSize Unlimited -Filter $filter -ErrorAction Stop
        }
    }

    $script:ExchangeRecipientCache = $recipients
    $script:ExchangeRecipientCacheDetailLevel = $DetailLevel
    return $recipients
}

<# Mail Domain section #>
function Get-MailDomainReport {
    Write-Host "Checking domains"
    $Domains = Get-DkimSigningConfig | Select-Object -Property Id, @{Name = "Default"; Expression = { $_.IsDefault } }, @{Name = "DKIM"; Expression = { $_.Enabled } }
    if (-not ($Domains)) { $Domains = Get-AcceptedDomain | Select-Object -Property Id, "Default", @{Name = "DKIM"; Expression = { $false } } }
    $DomainsReport = @()
    foreach ($Domain in $Domains) {
        $ProcessedCount++
        Write-Progress -Activity "Processed count: $ProcessedCount; Currently processing: $($Domain.Id)"
        $Domain = Get-DMARC -Domain $Domain
        $Domain = Get-SPF -Domain $Domain
        $DomainsReport += $Domain
    }
    Write-Progress -Activity "Processed count: $ProcessedCount; Currently processing: $($Domain.Id)" -Status "Ready" -Completed
    Add-TenantReportSection -Category 'Exchange Online' -Name 'Domains' -Data $DomainsReport
    $Report = $DomainsReport | ConvertTo-Html -As Table -Property Id, DKIM, DMARC, SPF, "DMARC record", "SPF record", "DMARC hint", "SPF hint", "Default" -Fragment -PreContent "<h3 id='EXO_DOMAIN'>Domains</h3>"
    $Report = $Report -Replace "<td>False</td><td>False</td><td>False</td>", "<td class='red'>False</td><td class='red'>False</td><td class='red'>False</td>"
    $Report = $Report -Replace "<td>False</td><td>False</td><td>True</td>", "<td class='red'>False</td><td class='red'>False</td><td>True</td>"
    $Report = $Report -Replace "<td>True</td><td>False</td><td>False</td>", "<td>True</td><td class='red'>False</td><td class='red'>False</td>"
    $Report = $Report -Replace "<td>True</td><td>False</td><td>True</td>", "<td>True</td><td class='red'>False</td><td>True</td>"
    $Report = $Report -Replace "<td>False</td><td>True</td><td>False</td>", "<td class='red'>False</td><td>True</td><td class='red'>False</td>"
    $Report = $Report -Replace "<td>False</td><td>True</td><td>True</td>", "<td class='red'>False</td><td>True</td><td>True</td>"
    $Report = $Report -Replace "<td>Should be p=reject</td>", "<td class='orange'>Should be p=reject</td>"
    $Report = $Report -Replace "<td>Not sufficiently stricth</td>", "<td class='orange'>Not sufficiently strict</td>"
    $Report = $Report -Replace "<td>Not effective enough</td>", "<td class='red'>Not effective enough</td>"
    $Report = $Report -Replace "<td>Does not protect</td>", "<td class='red'>Does not protect</td>"
    $Report = $Report -Replace "<td>No qualifier found</td>", "<td class='red'>No qualifier found</td>"
    return $Report
}

function Get-AllOffice365Domains {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, HelpMessage = 'Provide the service name')]
        [ValidateSet('MSOL', 'MGGraph', 'Azure')]
        [string]$ServiceName
    )

    Write-Host "Gathering domain inventory ($ServiceName)"

    function Get-RecipientCounts {
        param (
            [Parameter(Mandatory)]
            [array]$Recipients,

            [Parameter(Mandatory)]
            [string]$DomainName
        )

        $recipientsWithPrimary = ($Recipients | Where-Object { $_.PrimarySmtpAddress -like "*@${DomainName}" }).Count
        $recipientsWithAlias = ($Recipients | Where-Object {
                $addresses = @($_.EmailAddresses) -split ','
                $addresses -like "*@${DomainName}"
            }).Count
        $recipientsAliasOnly = ($Recipients | Where-Object {
                $addresses = @($_.EmailAddresses) -split ','
                ($addresses -like "smtp:*@${DomainName}") -and ($_.PrimarySmtpAddress -notlike "*@${DomainName}")
            }).Count

        [pscustomobject]@{
            PrimarySmtpCount = $recipientsWithPrimary
            AliasOnlyCount   = $recipientsAliasOnly
            AliasCount       = $recipientsWithAlias
        }
    }

    function Get-DnsHostCompanyName {
        param (
            [Parameter(Mandatory)]
            [array]$NsRecords
        )

        $dnsHostMapping = @{
            'ptd.net'               = 'PenTeleData'
            'comcast.net'           = 'Comcast'
            'charter.com'           = 'Charter Communications'
            'rr.com'                = 'Road Runner'
            'verizon.net'           = 'Verizon'
            'cox.net'               = 'Cox Communications'
            'sbcglobal.net'         = 'AT&T'
            'frontiernet.net'       = 'Frontier Communications'
            'earthlink.net'         = 'EarthLink'
            'oraclecloud.net'       = 'Oracle'
            'microsoft.com'         = 'Microsoft'
            'google.com'            = 'Google'
            'worldnic.com'          = 'Network Solutions'
            'cloudflare.com'        = 'Cloudflare'
            'domaincontrol.com'     = 'GoDaddy'
            'namecheaphosting.com'  = 'Namecheap'
        }

        if (-not $NsRecords) {
            return @()
        }

        $records = if ($NsRecords -is [array]) { $NsRecords } else { @($NsRecords) }

        $mainDomains = foreach ($record in $records) {
            $parts = $record.NameHost -split '\.'
            if ($parts.Length -ge 2) {
                $parts[-2..-1] -join '.'
            }
        }

        $uniqueMainDomains = $mainDomains | Where-Object { $_ } | Select-Object -Unique

        foreach ($domain in $uniqueMainDomains) {
            if ($dnsHostMapping.ContainsKey($domain)) {
                $dnsHostMapping[$domain]
            }
            else {
                $domain
            }
        }
    }

    try {
        switch ($ServiceName) {
            'MSOL' {
                $domains = Get-MsolDomain -ErrorAction Stop
            }
            'MGGraph' {
                $domains = Get-MgDomain -ErrorAction Stop | Where-Object { $_.Id }
            }
            'Azure' {
                $domains = Get-AzureADDomain -ErrorAction Stop
            }
        }
    }
    catch {
        Write-Warning "Unable to retrieve domain list from $ServiceName. $_"
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Domain inventory' -Message 'Error retrieving domain data'
        return "<br><h3 id='EXO_DOMAIN_INVENTORY'>Domain inventory</h3><p>Error retrieving domain data</p>"
    }

    if (-not $domains) {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Domain inventory'
        return "<br><h3 id='EXO_DOMAIN_INVENTORY'>Domain inventory</h3><p>Not found</p>"
    }

    $acceptedDomains = $null
    $remoteDomains = $null
    $recipientDataset = @()

    try {
        $acceptedDomains = Get-AcceptedDomain -ErrorAction Stop
        $remoteDomains = Get-RemoteDomain -ErrorAction Stop | Select-Object Identity, DomainName, IsInternal, TargetDeliveryDomain, AllowedOOFType, AutoReplyEnabled, AutoForwardEnabled, DeliveryReportEnabled, NDREnabled, MeetingForwardNotificationEnabled, ContentType, TNEFEnabled, TrustedMailOutboundEnabled, TrustedMailInboundEnabled
    }
    catch {
        Write-Verbose "Exchange Online domain details unavailable. $_"
    }

    try {
        $recipientDataset = Get-ExchangeRecipientDataset -DetailLevel 'combined'
    }
    catch {
        Write-Verbose "Unable to load recipient dataset for domain counts. $_"
    }

    $domainRows = foreach ($domain in $domains) {
        switch ($ServiceName) {
            'MSOL' {
                $domainName = $domain.Name
                $verified = $domain.Status
                $authType = $domain.Authentication
                $isDefault = $domain.IsDefault
            }
            { $_ -in 'MGGraph', 'Azure' } {
                $domainName = $domain.Id
                $verified = $domain.IsVerified
                $authType = $domain.AuthenticationType
                $isDefault = $domain.IsDefault
            }
        }

        $aRecords = Resolve-DnsName -Name $domainName -Server 1.1.1.1 -Type A -ErrorAction SilentlyContinue
        $mxRecords = Resolve-DnsName -Name $domainName -Server 1.1.1.1 -Type MX -ErrorAction SilentlyContinue
        $nsRecords = Resolve-DnsName -Name $domainName -Server 1.1.1.1 -Type NS -ErrorAction SilentlyContinue

        $dnsCompanies = if ($nsRecords) { Get-DnsHostCompanyName -NsRecords $nsRecords } else { @() }

        $domainType = $null
        if ($acceptedDomains) {
            $match = $acceptedDomains | Where-Object { $_.DomainName -eq $domainName }
            if ($match) {
                $domainType = $match.DomainType
            }
        }

        $recipientCounts = if ($recipientDataset) { Get-RecipientCounts -Recipients $recipientDataset -DomainName $domainName } else { $null }

        [pscustomobject]@{
            Domain                = $domainName
            Verified              = $verified
            AuthenticationType    = $authType
            DomainType            = $domainType
            IsDefault             = $isDefault
            DNSCompanies          = if ($dnsCompanies) { $dnsCompanies -join ',' } else { $null }
            NSRecords             = if ($nsRecords) { ($nsRecords.NameHost -join ',') } else { $null }
            ARecords              = if ($aRecords) { ($aRecords.IPAddress -join ',') } else { $null }
            MXRecords             = if ($mxRecords) { ($mxRecords.NameExchange -join ',') } else { $null }
            Office365MailExchanger = if ($mxRecords) { (($mxRecords.NameExchange | Out-String).Trim() -like '*protection.outlook.com') } else { $false }
            PrimarySMTPRecipients = if ($recipientCounts) { $recipientCounts.PrimarySmtpCount } else { $null }
            AliasOnlyRecipients   = if ($recipientCounts) { $recipientCounts.AliasOnlyCount } else { $null }
            AliasedRecipients     = if ($recipientCounts) { $recipientCounts.AliasCount } else { $null }
            ServiceName           = $ServiceName
        }
    }

    Add-TenantReportSection -Category 'Exchange Online' -Name 'Domain inventory' -Data $domainRows

    $remoteRows = @()
    if ($remoteDomains) {
        $remoteRows = $remoteDomains
        Add-TenantReportSection -Category 'Exchange Online' -Name 'Remote domains' -Data $remoteRows
    }

    $domainTable = $domainRows | Select-Object Domain, Verified, AuthenticationType, DomainType, Office365MailExchanger, PrimarySMTPRecipients, AliasedRecipients
    $domainHtml = $domainTable | ConvertTo-Html -As Table -Fragment -PreContent "<br><h3 id='EXO_DOMAIN_INVENTORY'>Domain inventory</h3>"

    if ($remoteRows -and $remoteRows.Count -gt 0) {
        $remoteTable = $remoteRows | Select-Object Identity, DomainName, IsInternal, TargetDeliveryDomain, AutoReplyEnabled, AutoForwardEnabled
        $remoteHtml = $remoteTable | ConvertTo-Html -As Table -Fragment -PreContent "<br><h3 id='EXO_REMOTE_DOMAINS'>Remote domains</h3>"
        return $domainHtml + $remoteHtml
    }

    return $domainHtml
}
function Get-DMARC {
    param($Domain)
    $DMARCRecord = (Resolve-Dns -Query "_dmarc.$($Domain.Id)" -QueryType TXT | Select-Object -Expand Answers).Text
    if ($null -eq $DMARCRecord ) {
        $DMARC = $false
    }
    else {
        switch -Regex ($DMARCRecord ) {
            ('p=none') {
                $DmarcHint = "Does not protect"
                $DMARC = $true
            }
            ('p=quarantine') {
                $DmarcHint = "Should be p=reject"
                $DMARC = $true
            }
            ('p=reject') {
                $DmarcHint = "Will protect"
                $DMARC = $true
            }
            ('sp=none') {
                $DmarcHint += "Does not protect"
                $DMARC = $true
            }
            ('sp=quarantine') {
                $DmarcHint += "Should be p=reject"
                $DMARC = $true
            }
            ('sp=reject') {
                $DmarcHint += "Will protect"
                $DMARC = $true
            }
        }
    }
    $Domain | Add-Member NoteProperty "DMARC" $DMARC
    $Domain | Add-Member NoteProperty "DMARC record" "$($DMARCRecord )"
    $Domain | Add-Member NoteProperty "DMARC hint" $DmarcHint
    return $Domain
}
function Get-SPF {
    param($Domain)
    $SPFRecord = (Resolve-Dns -Query $Domain.Id -QueryType TXT | Select-Object -Expand Answers).Text | Where-Object { $_ -match "v=spf1" }
    if ($SPFRecord -match "redirect") {
        $redirect = $SPFRecord.Split(" ")
        $RedirectName = $redirect -match "redirect" -replace "redirect="
        $SPFRecord = (Resolve-Dns -Query $RedirectName -QueryType TXT | Select-Object -Expand Answers).Text | Where-Object { $_ -match "v=spf1" }
    }
    if ($null -eq $SPFRecord) {
        $SPF = $false
    }
    if ($SPFRecord -is [array]) {
        $SPFHint = "More than one SPF-record"
        $SPF = $true
    }
    Else {
        switch -Regex ($SPFRecord) {
            '~all' {
                $SPFHint = "Not sufficiently strict"
                $SPF = $true
            }
            '-all' {
                $SPFHint = "Sufficiently strict"
                $SPF = $true
            }
            "\?all" {
                $SPFHint = "Not effective enough"
                $SPF = $true
            }
            '\+all' {
                $SPFHint = "Not effective enough"
                $SPF = $true
            }
            Default {
                $SPFHint = "No qualifier found"
                $SPF = $true
            }
        }
    }
    $Domain | Add-Member NoteProperty "SPF" "$($SPF)"
    $Domain | Add-Member NoteProperty "SPF record" "$($SPFRecord)"
    $Domain | Add-Member NoteProperty "SPF hint" $SPFHint
    return $Domain
}

<# Mail connector section#>
function Get-MailConnectorReport {
    Write-Host "Checking mail connectors"
    if (-not ($Inbound = Get-InboundConnector)) {
        $InboundReport = "<br><h3 id='EXO_CONNECTOR_IN'>Inbound mail connector</h3><p>Not found</p>"
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Inbound mail connector'
    }
    else {
        $InboundData = $Inbound | Select-Object Name, @{Name = 'SenderDomains'; Expression = { $_.SenderDomains -join '; ' } }, @{Name = 'SenderIPAddresses'; Expression = { $_.SenderIPAddresses -join '; ' } }, Enabled
        Add-TenantReportSection -Category 'Exchange Online' -Name 'Inbound mail connector' -Data $InboundData
        $InboundReport = $InboundData | ConvertTo-Html -As Table -Property Name, SenderDomains, SenderIPAddresses, Enabled -Fragment -PreContent "<br><h3 id='EXO_CONNECTOR_IN'>Inbound mail connector</h3>"
    }
    if (-not ($Outbound = Get-OutboundConnector -IncludeTestModeConnectors:$true)) {
        $OutboundReport = "<br><h3 id='EXO_CONNECTOR_OUT'>Outbound mail connector</h3><p>Not found</p>"
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Outbound mail connector'
    }
    else {
        $OutboundData = $Outbound | Select-Object Name, @{Name = 'RecipientDomains'; Expression = { $_.RecipientDomains -join '; ' } }, @{Name = 'SmartHosts'; Expression = { $_.SmartHosts -join '; ' } }, Enabled
        Add-TenantReportSection -Category 'Exchange Online' -Name 'Outbound mail connector' -Data $OutboundData
        $OutboundReport = $OutboundData | ConvertTo-Html -As Table -Property Name, RecipientDomains, SmartHosts, Enabled -Fragment -PreContent "<br><h3 id='EXO_CONNECTOR_OUT'>Outbound mail connector</h3>"
    }
    $Report = @()
    $Report += $InboundReport
    $Report += $OutboundReport
    return $Report
}

<# User mailbox section #>
function Get-AllRecipientDetails {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, HelpMessage = 'Provide the level of detail')]
        [ValidateSet('minimum', 'combined', 'all', 'geek')]
        [string]$DetailLevel
    )

    Write-Host "Checking Exchange Online recipients ($DetailLevel detail)"

    try {
        $recipients = Get-ExchangeRecipientDataset -DetailLevel $DetailLevel
    }
    catch {
        Write-Warning "Unable to retrieve Exchange Online recipients. $_"
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'All recipients' -Message 'Error retrieving recipients'
        return "<br><h3 id='EXO_RECIPIENTS'>All recipients</h3><p>Error retrieving recipient data</p>"
    }

    if (-not $recipients) {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'All recipients'
        return "<br><h3 id='EXO_RECIPIENTS'>All recipients</h3><p>Not found</p>"
    }

    switch ($DetailLevel) {
        'minimum' {
            $reportRows = foreach ($recipient in $recipients) {
                [pscustomobject]@{
                    DisplayName                   = $recipient.DisplayName
                    PrimarySmtpAddress            = $recipient.PrimarySmtpAddress
                    RecipientTypeDetails          = $recipient.RecipientTypeDetails
                    HiddenFromAddressListsEnabled = $recipient.HiddenFromAddressListsEnabled
                    WhenCreated                   = $recipient.WhenCreated
                    DetailLevel                   = $DetailLevel
                }
            }
        }
        'geek' {
            $reportRows = foreach ($recipient in $recipients) {
                $object = $recipient | Select-Object *
                if ($object.PSObject.Properties['DetailLevel']) {
                    $object.DetailLevel = $DetailLevel
                }
                else {
                    $object | Add-Member -NotePropertyName 'DetailLevel' -NotePropertyValue $DetailLevel -Force
                }
                $object
            }
        }
        Default {
            $reportRows = foreach ($recipient in $recipients) {
                [pscustomobject]@{
                    DisplayName                   = $recipient.DisplayName
                    PrimarySmtpAddress            = $recipient.PrimarySmtpAddress
                    RecipientTypeDetails          = $recipient.RecipientTypeDetails
                    HiddenFromAddressListsEnabled = $recipient.HiddenFromAddressListsEnabled
                    AddressBookPolicy             = $recipient.AddressBookPolicy
                    ManagedBy                     = Join-ReportValue -Value $recipient.ManagedBy
                    EmailAddresses                = Join-ReportValue -Value $recipient.EmailAddresses
                    SKUAssigned                   = Join-ReportValue -Value $recipient.SkuAssigned
                    WhenCreated                   = $recipient.WhenCreated
                    WhenSoftDeleted               = $recipient.WhenSoftDeleted
                    ExternalDirectoryObjectId     = $recipient.ExternalDirectoryObjectId
                    Guid                          = $recipient.Guid
                    Alias                         = $recipient.Alias
                    Notes                         = $recipient.Notes
                    DetailLevel                   = $DetailLevel
                }
            }
        }
    }

    Add-TenantReportSection -Category 'Exchange Online' -Name 'All recipients' -Data $reportRows

    $tableRows = $reportRows |
        Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails, HiddenFromAddressListsEnabled, WhenCreated

    return $tableRows | ConvertTo-Html -As Table -Property DisplayName, PrimarySmtpAddress, RecipientTypeDetails, HiddenFromAddressListsEnabled, WhenCreated `
        -Fragment -PreContent "<br><h3 id='EXO_RECIPIENTS'>All recipients</h3>"
}

function Get-ExchangeGroupDetails {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, HelpMessage = 'Provide the level of detail')]
        [ValidateSet('minimum', 'combined', 'all', 'geek')]
        [string]$DetailLevel
    )

    Write-Host "Checking Exchange Online groups ($DetailLevel detail)"

    try {
        $recipients = Get-ExchangeRecipientDataset -DetailLevel $DetailLevel
    }
    catch {
        Write-Warning "Unable to retrieve Exchange Online groups. $_"
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Group details' -Message 'Error retrieving group data'
        return "<br><h3 id='EXO_GROUPS'>Group details</h3><p>Error retrieving group data</p>"
    }

    $mailGroups = $recipients | Where-Object { $_.RecipientTypeDetails -like '*group' } | Sort-Object DisplayName

    if (-not $mailGroups) {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Group details'
        return "<br><h3 id='EXO_GROUPS'>Group details</h3><p>Not found</p>"
    }

    $groupRows = foreach ($group in $mailGroups) {
        $identity = $group.Identity.ToString()
        $groupDetails = $null
        $groupMembers = @()

        try {
            switch ($group.RecipientTypeDetails) {
                'DynamicDistributionGroup' {
                    $groupDetails = Get-DynamicDistributionGroup -Identity $identity -ErrorAction Stop
                    $groupMembers = Get-DynamicDistributionGroupMember -Identity $identity -ErrorAction SilentlyContinue -ResultSize Unlimited
                }
                'GroupMailbox' {
                    $groupDetails = Get-UnifiedGroup -Identity $identity -ErrorAction Stop
                    $groupMembers = Get-UnifiedGroupLinks -Identity $identity -LinkType Member -ErrorAction SilentlyContinue -ResultSize Unlimited
                }
                Default {
                    $groupDetails = Get-DistributionGroup -Identity $identity -ErrorAction Stop
                    $groupMembers = Get-DistributionGroupMember -Identity $identity -ErrorAction SilentlyContinue -ResultSize Unlimited
                }
            }
        }
        catch {
            Write-Warning "Failed to gather details for group $identity. $_"
        }

        $ownerValues = @($group.ManagedBy) | Where-Object { $_ }
        $ownersCount = if ($ownerValues) { $ownerValues.Count } else { 0 }
        $groupOwners = if ($ownerValues) { Join-ReportValue -Value $ownerValues } else { $null }

        $memberValues = foreach ($member in @($groupMembers)) {
            if (-not $member) { continue }

            if ($member.PSObject.Properties['PrimarySmtpAddress']) {
                $member.PrimarySmtpAddress
                continue
            }

            if ($member.PSObject.Properties['UserPrincipalName']) {
                $member.UserPrincipalName
                continue
            }

            if ($member.PSObject.Properties['Name']) {
                $member.Name
                continue
            }

            $member.ToString()
        }

        $membersCount = if ($memberValues) { $memberValues.Count } else { 0 }
        $groupMembersList = if ($memberValues) { ($memberValues -join ', ') } else { $null }

        [pscustomobject]@{
            DisplayName                            = $group.DisplayName
            Identity                               = $identity
            Alias                                  = $group.Alias
            Notes                                  = $group.Notes
            HiddenFromAddressListsEnabled          = $group.HiddenFromAddressListsEnabled
            PrimarySmtpAddress                     = $group.PrimarySMTPAddress
            RecipientTypeDetails                   = $group.RecipientTypeDetails
            EmailAddresses                         = Join-ReportValue -Value $group.EmailAddresses
            Owners                                 = $groupOwners
            OwnersCount                            = $ownersCount
            Members                                = $groupMembersList
            MembersCount                           = $membersCount
            ResourceProvisioningOptions            = if ($groupDetails) { Join-ReportValue -Value $groupDetails.ResourceProvisioningOptions } else { $null }
            IsMailboxConfigured                    = if ($groupDetails) { $groupDetails.IsMailboxConfigured } else { $null }
            HiddenGroupMembershipEnabled           = if ($groupDetails) { Join-ReportValue -Value $groupDetails.HiddenGroupMembershipEnabled } else { $null }
            ModeratedBy                            = if ($groupDetails) { Join-ReportValue -Value $groupDetails.ModeratedBy } else { $null }
            RequireSenderAuthenticationEnabled     = if ($groupDetails) { $groupDetails.RequireSenderAuthenticationEnabled } else { $null }
            AcceptMessagesOnlyFrom                 = if ($groupDetails) { Join-ReportValue -Value $groupDetails.AcceptMessagesOnlyFrom } else { $null }
            AcceptMessagesOnlyFromDLMembers        = if ($groupDetails) { Join-ReportValue -Value $groupDetails.AcceptMessagesOnlyFromDLMembers } else { $null }
            AcceptMessagesOnlyFromSendersOrMembers = if ($groupDetails) { Join-ReportValue -Value $groupDetails.AcceptMessagesOnlyFromSendersOrMembers } else { $null }
            RejectMessagesFrom                     = if ($groupDetails) { Join-ReportValue -Value $groupDetails.RejectMessagesFrom } else { $null }
            RejectMessagesFromDLMembers            = if ($groupDetails) { Join-ReportValue -Value $groupDetails.RejectMessagesFromDLMembers } else { $null }
            RejectMessagesFromSendersOrMembers     = if ($groupDetails) { Join-ReportValue -Value $groupDetails.RejectMessagesFromSendersOrMembers } else { $null }
            AccessType                             = if ($groupDetails) { $groupDetails.AccessType } else { $null }
            AllowAddGuests                         = if ($groupDetails) { $groupDetails.AllowAddGuests } else { $null }
            SharePointSiteUrl                      = if ($groupDetails) { $groupDetails.SharePointSiteUrl } else { $null }
            DetailLevel                            = $DetailLevel
        }
    }

    Add-TenantReportSection -Category 'Exchange Online' -Name 'Group details' -Data $groupRows

    $tableRows = $groupRows | Select-Object DisplayName, PrimarySmtpAddress, RecipientTypeDetails, OwnersCount, MembersCount, HiddenFromAddressListsEnabled

    return $tableRows | ConvertTo-Html -As Table -Property DisplayName, PrimarySmtpAddress, RecipientTypeDetails, OwnersCount, MembersCount, HiddenFromAddressListsEnabled `
        -Fragment -PreContent "<br><h3 id='EXO_GROUPS'>Group details</h3>"
}

function Get-AllPublicFolderDetails {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, HelpMessage = 'Provide the level of detail')]
        [ValidateSet('minimum', 'combined', 'all', 'geek')]
        [string]$DetailLevel,

        [Parameter(HelpMessage = 'Specify Exchange Environment')]
        [ValidateSet('On-Premises', 'Office365')]
        [string]$ExchangeEnvironment = 'Office365'
    )

    Write-Host "Checking public folders ($ExchangeEnvironment, $DetailLevel detail)"

    try {
        switch ($DetailLevel) {
            'geek' {
                $publicFolders = Get-PublicFolder -Recurse -ResultSize Unlimited -ErrorAction Stop | Where-Object { $_.Name -ne 'IPM_SUBTREE' }
            }
            default {
                $desiredProperties = @(
                    'Identity', 'Name', 'MailEnabled',
                    'MailRecipientGuid', 'ParentPath', 'ContentMailboxName',
                    'EntryId', 'FolderSize', 'HasSubfolders',
                    'FolderClass', 'FolderPath', 'ExtendedFolderFlags'
                )

                $publicFolders = Get-PublicFolder -Recurse -ResultSize Unlimited -ErrorAction Stop |
                    Where-Object { $_.Name -ne 'IPM_SUBTREE' } |
                    Select-Object -Property $desiredProperties
            }
        }
    }
    catch {
        Write-Warning "Unable to retrieve public folders. $_"
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Public folders' -Message 'Error retrieving public folders'
        return "<br><h3 id='EXO_PUBLIC_FOLDERS'>Public folders</h3><p>Error retrieving public folder data</p>"
    }

    if (-not $publicFolders) {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Public folders'
        return "<br><h3 id='EXO_PUBLIC_FOLDERS'>Public folders</h3><p>Not found</p>"
    }

    $stats = @{}
    try {
        $statsParams = @{ ErrorAction = 'SilentlyContinue' }
        if ($ExchangeEnvironment -eq 'On-Premises' -and (Get-Command -Name Get-PublicFolderDatabase -ErrorAction SilentlyContinue)) {
            $database = Get-PublicFolderDatabase -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($database) {
                $statsParams['Server'] = $database.Identity
            }
        }

        $folderStats = $publicFolders | Get-PublicFolderStatistics @statsParams
        foreach ($item in @($folderStats)) {
            if ($null -ne $item.EntryId) {
                $stats[$item.EntryId] = $item
            }
        }
    }
    catch {
        Write-Warning "Unable to retrieve public folder statistics. $_"
    }

    $permissions = @()
    try {
        $permissions = $publicFolders | Get-PublicFolderClientPermission -ErrorAction SilentlyContinue
    }
    catch {
        Write-Warning "Unable to retrieve public folder permissions. $_"
    }

    $detailRows = foreach ($folder in $publicFolders) {
        $stat = $stats[$folder.EntryId]

        [pscustomobject]@{
            Name                     = $folder.Name
            FolderPath               = if ($folder.PSObject.Properties['FolderPath']) { Join-ReportValue -Value $folder.FolderPath } else { $folder.Identity }
            MailEnabled              = $folder.MailEnabled
            ContentMailboxName       = $folder.ContentMailboxName
            HasSubfolders            = $folder.HasSubfolders
            FolderClass              = $folder.FolderClass
            FolderSize               = if ($folder.FolderSize) { $folder.FolderSize.ToString() } else { $null }
            ItemCount                = if ($stat) { $stat.ItemCount } else { $null }
            LastModificationTime     = if ($stat) { $stat.LastModificationTime } else { $null }
            OwnerCount               = if ($stat) { $stat.OwnerCount } else { $null }
            TotalAssociatedItemSize  = if ($stat) { $stat.TotalAssociatedItemSize } else { $null }
            TotalDeletedItemSize     = if ($stat) { $stat.TotalDeletedItemSize } else { $null }
            TotalItemSize            = if ($stat) { $stat.TotalItemSize } else { $null }
            MailboxOwnerId           = if ($stat) { $stat.MailboxOwnerId } else { $null }
            DetailLevel              = $DetailLevel
        }
    }

    Add-TenantReportSection -Category 'Exchange Online' -Name 'Public folders' -Data $detailRows

    $permissionRows = foreach ($permission in @($permissions)) {
        [pscustomobject]@{
            FolderPath          = $permission.Identity
            FolderName          = $permission.FolderName
            DisplayName         = $permission.User.DisplayName
            PrimarySmtpAddress  = if ($permission.User.RecipientPrincipal) { $permission.User.RecipientPrincipal.PrimarySmtpAddress } else { $null }
            AccessRights        = Join-ReportValue -Value $permission.AccessRights
            DetailLevel         = $DetailLevel
        }
    }

    if ($permissionRows) {
        Add-TenantReportSection -Category 'Exchange Online' -Name 'Public folder permissions' -Data $permissionRows
    }
    else {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Public folder permissions'
    }

    $detailsHtml = $detailRows | Select-Object Name, FolderPath, MailEnabled, ItemCount, TotalItemSize |
        ConvertTo-Html -As Table -Property Name, FolderPath, MailEnabled, ItemCount, TotalItemSize `
            -Fragment -PreContent "<br><h3 id='EXO_PUBLIC_FOLDERS'>Public folders</h3>"

    $permissionsHtml = if ($permissionRows) {
        $permissionRows | Select-Object FolderPath, DisplayName, PrimarySmtpAddress, AccessRights |
            ConvertTo-Html -As Table -Property FolderPath, DisplayName, PrimarySmtpAddress, AccessRights `
                -Fragment -PreContent "<br><h3 id='EXO_PUBLIC_FOLDER_PERMISSIONS'>Public folder permissions</h3>"
    }
    else {
        "<br><h3 id='EXO_PUBLIC_FOLDER_PERMISSIONS'>Public folder permissions</h3><p>Not found</p>"
    }

    return @($detailsHtml, $permissionsHtml)
}

function Get-UserMailboxReport {
    param(
        [System.Boolean]$Language
    )
    Write-Host "Checking user mailboxes"
    if ( -not ($Mailboxes = Get-EXOMailbox -RecipientTypeDetails UserMailbox -ResultSize:Unlimited -Properties DisplayName, UserPrincipalName)) {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'User mailbox'
        return "<br><h3 id='EXO_USER'>User mailbox</h3><p>Not found</p>"
    }
    if ($Language) {
        Update-MailboxLang -Mailbox $Mailboxes
    }
    $MailboxReport = @()
    foreach ($Mailbox in $Mailboxes) {
        $ProcessedCount++
        Write-Progress -Activity "Processed count: $ProcessedCount; Currently processing: $($Mailbox.DisplayName)"
        $MailboxReport += Get-MailboxLoginAndLocation $Mailbox
    }
    Write-Progress -Activity "Processed count: $ProcessedCount; Currently processing: $($Mailbox.DisplayName)" -Status "Ready" -Completed
    $UserMailboxData = $MailboxReport | Select-Object UserPrincipalName, DisplayName, Language, TimeZone, LoginAllowed
    Add-TenantReportSection -Category 'Exchange Online' -Name 'User mailbox' -Data $UserMailboxData
    return $UserMailboxData | ConvertTo-Html -As Table -Property UserPrincipalName, DisplayName, Language, TimeZone, LoginAllowed `
        -Fragment -PreContent "<br><h3 id='EXO_USER'>User mailbox</h3>"
}
function Update-MailboxLang {
    param(
        $Mailbox
    )
    Write-Host "Setting mailboxes language:" $script:MailboxLanguageCode "timezone:" $script:MailboxTimeZone
    $Mailbox | Set-MailboxRegionalConfiguration -LocalizeDefaultFolderName:$true -Language $script:MailboxLanguageCode -TimeZone $script:MailboxTimeZone
}

<# Shared mailbox section #>
function Get-SharedMailboxReport {
    param(
        [System.Boolean]$Language,
        [System.Boolean]$DisableLogin,
        [System.Boolean]$EnableCopy
    )
    Write-Host "Checking shared mailboxes"
    if ( -not ($Mailboxes = Get-EXOMailbox -RecipientTypeDetails SharedMailbox -ResultSize:Unlimited -Properties DisplayName,
            UserPrincipalName, MessageCopyForSentAsEnabled, MessageCopyForSendOnBehalfEnabled)) {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Shared mailbox'
        return "<br><h3 id='EXO_SHARED'>Shared mailbox</h3><p>Not found</p>"
    }
    if ($Language) { Update-MailboxLang -Mailbox $Mailboxes }
    if ($DisableLogin) { Disable-UserAccount $Mailboxes }
    if ($EnableCopy) {
        Enable-SharedMailboxEnableCopyToSent $Mailboxes
        $Mailboxes = Get-EXOMailbox -RecipientTypeDetails SharedMailbox -ResultSize:Unlimited -Properties DisplayName,
        UserPrincipalName, MessageCopyForSentAsEnabled, MessageCopyForSendOnBehalfEnabled
    }
    $MailboxReport = @()
    foreach ($Mailbox in $Mailboxes) {
        $ProcessedCount++
        Write-Progress -Activity "Processed count: $ProcessedCount; Currently processing: $($Mailbox.DisplayName)"
        $MailboxReport += Get-MailboxLoginAndLocation $Mailbox
    }
    Write-Progress -Activity "Processed count: $ProcessedCount; Currently processing: $($Mailbox.DisplayName)" -Status "Ready" -Completed
    $SharedMailboxData = $MailboxReport | Select-Object UserPrincipalName, DisplayName, Language, TimeZone, MessageCopyForSentAsEnabled,
    MessageCopyForSendOnBehalfEnabled, LoginAllowed
    Add-TenantReportSection -Category 'Exchange Online' -Name 'Shared mailbox' -Data $SharedMailboxData
    $Report = $SharedMailboxData | ConvertTo-Html -As Table -Property UserPrincipalName, DisplayName, Language, TimeZone, MessageCopyForSentAsEnabled,
    MessageCopyForSendOnBehalfEnabled, LoginAllowed -Fragment -PreContent "<br><h3 id='EXO_SHARED'>Shared mailbox</h3>"
    $Report = $Report -Replace "<td>True</td><td>True</td><td>True</td>", "<td>True</td><td>True</td><td class='red'>True</td>"
    $Report = $Report -Replace "<td>False</td><td>False</td><td>True</td>", "<td>False</td><td>False</td><td class='red'>True</td>"
    $Report = $Report -Replace "<td>True</td><td>False</td><td>True</td>", "<td>True</td><td>False</td><td class='red'>True</td>"
    $Report = $Report -Replace "<td>False</td><td>True</td><td>True</td>", "<td>False</td><td>True</td><td class='red'>True</td>"
    return $Report
}
function Get-MailboxLoginAndLocation {
    param (
        $Mailbox
    )
    $ReginalConfig = $Mailbox | Get-MailboxRegionalConfiguration
    Add-Member -InputObject $Mailbox -NotePropertyName "Language" -NotePropertyValue $ReginalConfig.Language
    Add-Member -InputObject $Mailbox -NotePropertyName "TimeZone" -NotePropertyValue $ReginalConfig.TimeZone
    Add-Member -InputObject $Mailbox -NotePropertyName "LoginAllowed" -NotePropertyValue (Request-UserAccountStatus $Mailbox.UserPrincipalName)
    return $Mailbox
}
function Enable-SharedMailboxEnableCopyToSent {
    param(
        $Mailbox
    )
    Write-Host "Enable shared mailbox copy to sent"
    $Mailbox | Set-Mailbox -MessageCopyForSentAsEnabled $True -MessageCopyForSendOnBehalfEnabled $True
}

<# Unified mailbox section #>
function Get-UnifiedMailboxReport {
    param(
        [System.Boolean]$HideFromClient
    )
    Write-Host "Checking unified mailboxes"
    if ( -not ($Mailboxes = Get-UnifiedGroup -ResultSize Unlimited)) {
        Add-TenantReportStatus -Category 'Exchange Online' -Name 'Unified mailbox'
        return "<br><h3 id='EXO_UNIFIED'>Unified mailbox</h3><p>Not found</p>"
    }
    if ($HideFromClient) {
        Write-Host "Hiding unified mailboxes from outlook client"
        $Mailboxes | Set-UnifiedGroup -HiddenFromExchangeClientsEnabled:$true -HiddenFromAddressListsEnabled:$false
        $Mailboxes = Get-UnifiedGroup -ResultSize Unlimited 
    }
    $UnifiedData = $Mailboxes | Sort-Object -Property PrimarySmtpAddress | Select-Object DisplayName, PrimarySmtpAddress, HiddenFromAddressListsEnabled, HiddenFromExchangeClientsEnabled
    Add-TenantReportSection -Category 'Exchange Online' -Name 'Unified mailbox' -Data $UnifiedData
    return $UnifiedData | ConvertTo-Html -As Table -Property DisplayName, PrimarySmtpAddress, HiddenFromAddressListsEnabled, HiddenFromExchangeClientsEnabled -Fragment -PreContent "<br><h3 id='EXO_UNIFIED'>Unified mailbox</h3>" -PostContent "<p>Unified groups = Microsoft 365 groups</p>"
}