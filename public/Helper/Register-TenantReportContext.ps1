function Initialize-TenantReportContext {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Title,

        [Parameter()]
        [string]$Version
    )

    $script:TenantReportContext = [ordered]@{
        Title          = $Title
        Version        = $Version
        Generated      = Get-Date
        Sections       = [ordered]@{}
        WorksheetNames = @{}
    }

    $metadata = [pscustomobject]@{
        Title    = $Title
        Version  = $Version
        Generated = $script:TenantReportContext.Generated
    }

    $script:TenantReportContext.Sections['Report Metadata'] = New-Object System.Collections.Generic.List[object]
    $null = $script:TenantReportContext.Sections['Report Metadata'].Add($metadata)
}

function Reset-TenantReportContext {
    [CmdletBinding()]
    param()

    $script:TenantReportContext = $null
}

function Add-TenantReportSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [object[]]$Data,

        [Parameter()]
        [string]$Category,

        [Parameter()]
        [string]$EmptyMessage = 'No data available'
    )

    if (-not $script:TenantReportContext) {
        Initialize-TenantReportContext -Title $script:ReportTitle -Version $script:ModuleVersion
    }

    if ([string]::IsNullOrEmpty($Name)) {
        throw 'Section name cannot be empty.'
    }

    $sectionKey = if ([string]::IsNullOrWhiteSpace($Category)) { $Name } else { "${Category}\$Name" }

    if (-not $script:TenantReportContext.Sections.Contains($sectionKey)) {
        $script:TenantReportContext.Sections[$sectionKey] = New-Object System.Collections.Generic.List[object]
    }

    if (-not $Data -or $Data.Count -eq 0) {
        $null = $script:TenantReportContext.Sections[$sectionKey].Add([pscustomobject]@{ Status = $EmptyMessage })
        return
    }

    foreach ($item in $Data) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [System.Collections.IDictionary]) {
            $object = [pscustomobject]$item
        }
        elseif ($item -is [System.Management.Automation.PSObject]) {
            $object = $item | Select-Object *
        }
        else {
            $object = [pscustomobject]$item
        }

        $null = $script:TenantReportContext.Sections[$sectionKey].Add($object)
    }
}

function Add-TenantReportStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Message = 'Not found',

        [Parameter()]
        [string]$Category
    )

    Add-TenantReportSection -Name $Name -Category $Category -Data @([pscustomobject]@{ Status = $Message })
}

function Get-TenantReportSections {
    [CmdletBinding()]
    param()

    if (-not $script:TenantReportContext) {
        return @{}
    }

    return $script:TenantReportContext.Sections
}

function Get-TenantReportWorksheetName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$Index
    )

    if (-not $script:TenantReportContext) {
        Initialize-TenantReportContext -Title $script:ReportTitle -Version $script:ModuleVersion
    }

    $cleanName = $Name -replace '[\\\*\?/\[\]:]', ' '
    $cleanName = ($cleanName -split '\s+') -join ' '
    $cleanName = $cleanName.Trim()

    if ([string]::IsNullOrEmpty($cleanName)) {
        $cleanName = "Sheet$Index"
    }

    if ($cleanName.Length -gt 31) {
        $cleanName = $cleanName.Substring(0, 31)
    }

    if (-not $script:TenantReportContext.WorksheetNames) {
        $script:TenantReportContext.WorksheetNames = @{}
    }

    $candidate = $cleanName
    $suffix = 1
    while ($script:TenantReportContext.WorksheetNames.ContainsKey($candidate)) {
        $baseName = $cleanName
        if ($baseName.Length -gt 28) {
            $baseName = $baseName.Substring(0, 28)
        }
        $candidate = "${baseName}_$suffix"
        if ($candidate.Length -gt 31) {
            $candidate = $candidate.Substring(0, 31)
        }
        $suffix++
    }

    $script:TenantReportContext.WorksheetNames[$candidate] = $true
    return $candidate
}

function Export-TenantReportExcel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $sections = Get-TenantReportSections
    if (-not $sections.Keys.Count) {
        Write-Verbose 'No tenant report data available for Excel export.'
        return
    }

    try {
        Import-Module -Name ImportExcel -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "ImportExcel module is not available. Skipping Excel export. $_"
        return
    }

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }

    $index = 1
    foreach ($entry in $sections.GetEnumerator()) {
        $rows = $entry.Value
        if (-not $rows -or $rows.Count -eq 0) {
            $rows = @([pscustomobject]@{ Status = 'No data available' })
        }

        $worksheetName = Get-TenantReportWorksheetName -Name $entry.Key -Index $index
        $tableName = "Tbl$index" + ($worksheetName -replace '[^A-Za-z0-9]', '')

        $params = @{
            Path          = $Path
            WorksheetName = $worksheetName
            TableName     = $tableName
            InputObject   = $rows
            AutoSize      = $true
            AutoFilter    = $true
            FreezeTopRow  = $true
            BoldTopRow    = $true
            TableStyle    = 'Medium2'
        }

        if ($index -eq 1) {
            $params['ClearSheet'] = $true
        }

        Export-Excel @params
        $index++
    }
}
