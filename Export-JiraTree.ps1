<#
.SYNOPSIS
    Recursively exports a Jira issue and all of its descendant subtasks/child issues
    to Markdown, HTML, and JSON files.

.DESCRIPTION
    Starting from -RootIssue, this script walks the issue tree depth-first (via
    `parent = <key>` JQL search) and collects each issue's key, summary,
    description, type, status, assignee, priority, and Jira URL. Rich-text
    descriptions (Atlassian Document Format) are converted to plain text.

.PARAMETER Site
    Base URL of your Jira Cloud site, e.g. https://your-domain.atlassian.net

.PARAMETER Email
    Atlassian account email used for API authentication. Prompted for if omitted.

.PARAMETER RootIssue
    The issue key to start exporting from, e.g. KAN-182. Always prompted for if
    omitted (deliberately not read from .env — this is expected to change often).

.PARAMETER OutputDirectory
    Directory to write <RootIssue>.md / .html / .json into. Defaults to .\jira-export

.PARAMETER ApiToken
    Atlassian API token (create one at https://id.atlassian.com/manage-profile/security/api-tokens).
    If omitted, the token is read from the JIRA_API_TOKEN environment variable (which can
    come from a .env file next to this script — see .env.example), and if that is also
    unset, you are prompted for it interactively (input is masked).

.EXAMPLE
    .\Export-JiraTree.ps1 -Site "https://your-domain.atlassian.net" -Email "you@example.com" -RootIssue "KAN-182"

.EXAMPLE
    # Copy .env.example to .env, fill in JIRA_SITE/JIRA_EMAIL/JIRA_API_TOKEN, then:
    .\Export-JiraTree.ps1
    # (you'll still be prompted for the root issue key each run)
#>
param(
    [string]$Site = "",
    [string]$Email = "",
    [string]$RootIssue = "",
    [string]$OutputDirectory = ".\jira-export",
    [string]$ApiToken = ""
)

$ErrorActionPreference = "Stop"

function Import-DotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed -eq "" -or $trimmed.StartsWith("#")) {
            continue
        }

        $separatorIndex = $trimmed.IndexOf("=")
        if ($separatorIndex -lt 1) {
            continue
        }

        $name = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1).Trim()
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        if ([string]::IsNullOrWhiteSpace((Get-Item -Path "env:$name" -ErrorAction SilentlyContinue).Value)) {
            Set-Item -Path "env:$name" -Value $value
        }
    }
}

Import-DotEnv (Join-Path $PSScriptRoot ".env")

if ([string]::IsNullOrWhiteSpace($RootIssue)) {
    $RootIssue = Read-Host "Root issue key (e.g. KAN-182)"
}
$RootIssue = $RootIssue.Trim().ToUpperInvariant()

if ([string]::IsNullOrWhiteSpace($Site)) {
    $Site = $env:JIRA_SITE
}
if ([string]::IsNullOrWhiteSpace($Site)) {
    $Site = Read-Host "Jira site URL (e.g. https://your-domain.atlassian.net)"
}
$Site = $Site.TrimEnd("/")

if ([string]::IsNullOrWhiteSpace($Email)) {
    $Email = $env:JIRA_EMAIL
}
if ([string]::IsNullOrWhiteSpace($Email)) {
    $Email = Read-Host "Atlassian account email"
}

if (-not [string]::IsNullOrWhiteSpace($ApiToken)) {
    $apiToken = $ApiToken
}
elseif (-not [string]::IsNullOrWhiteSpace($env:JIRA_API_TOKEN)) {
    $apiToken = $env:JIRA_API_TOKEN
}
else {
    $secureToken = Read-Host "Atlassian API token" -AsSecureString
    $tokenPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    try {
        $apiToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPtr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPtr)
    }
}

$credentialText = "$($Email):$apiToken"
$encodedCredential = [Convert]::ToBase64String(
    [Text.Encoding]::UTF8.GetBytes($credentialText)
)

$script:Headers = @{
    Authorization  = "Basic $encodedCredential"
    Accept         = "application/json"
    "Content-Type" = "application/json"
}
$script:Site = $Site
$apiToken = $null
$credentialText = $null

function Invoke-JiraRequestWithRetry {
    param([Parameter(Mandatory = $true)][scriptblock]$Request)

    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return (& $Request)
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 429 -and $attempt -lt $maxAttempts) {
                $retryAfter = 5
                if ($_.Exception.Response.Headers -and $_.Exception.Response.Headers.RetryAfter) {
                    $retryAfter = [Math]::Max(1, [int]$_.Exception.Response.Headers.RetryAfter.Delta.TotalSeconds)
                }
                Write-Host "Rate limited by Jira, waiting ${retryAfter}s before retrying (attempt $attempt/$maxAttempts)..."
                Start-Sleep -Seconds $retryAfter
                continue
            }

            throw
        }
    }
}

function Invoke-JiraGet {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        return Invoke-JiraRequestWithRetry {
            Invoke-RestMethod `
                -Method Get `
                -Uri "$script:Site$Path" `
                -Headers $script:Headers
        }
    }
    catch {
        $details = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $details += "`n" + $_.ErrorDetails.Message
        }
        throw "Jira GET failed: $Path`n$details"
    }
}

function Invoke-JiraPost {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Body
    )

    try {
        $jsonBody = $Body | ConvertTo-Json -Depth 20
        return Invoke-JiraRequestWithRetry {
            Invoke-RestMethod `
                -Method Post `
                -Uri "$script:Site$Path" `
                -Headers $script:Headers `
                -Body $jsonBody
        }
    }
    catch {
        $details = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $details += "`n" + $_.ErrorDetails.Message
        }
        throw "Jira POST failed: $Path`n$details"
    }
}

function Convert-AdfToText {
    param([object]$Node)

    if ($null -eq $Node) {
        return ""
    }

    if ($Node -is [string]) {
        return [string]$Node
    }

    $type = [string]$Node.type

    switch ($type) {
        "text" {
            return [string]$Node.text
        }
        "hardBreak" {
            return "`n"
        }
        "mention" {
            if ($Node.attrs -and $Node.attrs.text) {
                return [string]$Node.attrs.text
            }
            return "@mention"
        }
        "emoji" {
            if ($Node.attrs -and $Node.attrs.text) {
                return [string]$Node.attrs.text
            }
            if ($Node.attrs -and $Node.attrs.shortName) {
                return [string]$Node.attrs.shortName
            }
            return ""
        }
        "inlineCard" {
            if ($Node.attrs -and $Node.attrs.url) {
                return [string]$Node.attrs.url
            }
            return ""
        }
        "media" {
            if ($Node.attrs -and $Node.attrs.alt) {
                return "[media: $($Node.attrs.alt)]"
            }
            return "[media]"
        }
        "rule" {
            return "`n---`n"
        }
        "bulletList" {
            $items = New-Object System.Collections.Generic.List[string]
            foreach ($child in @($Node.content)) {
                $itemText = (Convert-AdfToText $child).Trim()
                if (-not [string]::IsNullOrWhiteSpace($itemText)) {
                    $items.Add("- $itemText")
                }
            }
            if ($items.Count -eq 0) {
                return ""
            }
            return ($items -join "`n") + "`n`n"
        }
        "orderedList" {
            $items = New-Object System.Collections.Generic.List[string]
            $index = 1
            foreach ($child in @($Node.content)) {
                $itemText = (Convert-AdfToText $child).Trim()
                if (-not [string]::IsNullOrWhiteSpace($itemText)) {
                    $items.Add("$index. $itemText")
                    $index++
                }
            }
            if ($items.Count -eq 0) {
                return ""
            }
            return ($items -join "`n") + "`n`n"
        }
    }

    $text = ""
    foreach ($child in @($Node.content)) {
        $text += (Convert-AdfToText $child)
    }

    switch ($type) {
        "paragraph"  { return $text.TrimEnd() + "`n`n" }
        "heading"    { return $text.TrimEnd() + "`n`n" }
        "blockquote" { return $text.TrimEnd() + "`n`n" }
        "codeBlock"  { return $text.TrimEnd() + "`n`n" }
        "listItem"   { return $text.TrimEnd() + "`n" }
        "tableCell"  { return $text.Trim() + "`t" }
        "tableHeader" { return $text.Trim() + "`t" }
        "tableRow"   { return $text.TrimEnd("`t") + "`n" }
        "table"      { return $text.TrimEnd() + "`n`n" }
        default       { return $text }
    }
}

function Get-JiraIssue {
    param([Parameter(Mandatory = $true)][string]$Key)

    $encodedKey = [Uri]::EscapeDataString($Key)
    $fieldList = "summary,description,status,assignee,priority,issuetype,parent"
    $encodedFields = [Uri]::EscapeDataString($fieldList)
    return (Invoke-JiraGet "/rest/api/3/issue/${encodedKey}?fields=$encodedFields")
}

function Get-ChildIssueKeys {
    param([Parameter(Mandatory = $true)][string]$ParentKey)

    $resultKeys = New-Object System.Collections.Generic.List[string]
    $nextPageToken = $null

    do {
        $body = @{
            jql        = "parent = `"$ParentKey`" ORDER BY created ASC"
            fields     = @("key")
            maxResults = 100
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$nextPageToken)) {
            $body["nextPageToken"] = $nextPageToken
        }

        $response = Invoke-JiraPost "/rest/api/3/search/jql" $body

        foreach ($issue in @($response.issues)) {
            if ($issue.key) {
                $resultKeys.Add([string]$issue.key)
            }
        }

        $nextPageToken = $response.nextPageToken
    }
    while (-not [string]::IsNullOrWhiteSpace([string]$nextPageToken))

    return $resultKeys.ToArray()
}

$script:Visited = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

function Get-IssueTree {
    param([Parameter(Mandatory = $true)][string]$Key)

    if (-not $script:Visited.Add($Key)) {
        return $null
    }

    Write-Host "Reading $Key ..."
    $issue = Get-JiraIssue $Key

    $description = (Convert-AdfToText $issue.fields.description).Trim()
    $assignee = "Unassigned"
    if ($issue.fields.assignee) {
        $assignee = [string]$issue.fields.assignee.displayName
    }

    $priority = ""
    if ($issue.fields.priority) {
        $priority = [string]$issue.fields.priority.name
    }

    $children = @()
    foreach ($childKey in @(Get-ChildIssueKeys $Key)) {
        $childNode = Get-IssueTree $childKey
        if ($null -ne $childNode) {
            $children += $childNode
        }
    }

    return [PSCustomObject]@{
        key         = [string]$issue.key
        title       = [string]$issue.fields.summary
        description = $description
        issueType   = [string]$issue.fields.issuetype.name
        status      = [string]$issue.fields.status.name
        assignee    = $assignee
        priority    = $priority
        url         = "$script:Site/browse/$($issue.key)"
        children    = $children
    }
}

function Convert-NodeToMarkdown {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [int]$Depth = 0
    )

    $headingLevel = [Math]::Min($Depth + 1, 6)
    $heading = "#" * $headingLevel
    $builder = New-Object System.Text.StringBuilder

    [void]$builder.AppendLine("$heading $($Node.key) - $($Node.title)")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("- Type: $($Node.issueType)")
    [void]$builder.AppendLine("- Status: $($Node.status)")
    [void]$builder.AppendLine("- Assignee: $($Node.assignee)")
    if (-not [string]::IsNullOrWhiteSpace($Node.priority)) {
        [void]$builder.AppendLine("- Priority: $($Node.priority)")
    }
    [void]$builder.AppendLine("- Jira: $($Node.url)")
    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("**Description**")
    [void]$builder.AppendLine("")

    if ([string]::IsNullOrWhiteSpace($Node.description)) {
        [void]$builder.AppendLine("(No description)")
    }
    else {
        [void]$builder.AppendLine($Node.description)
    }

    [void]$builder.AppendLine("")
    [void]$builder.AppendLine("---")
    [void]$builder.AppendLine("")

    foreach ($child in @($Node.children)) {
        [void]$builder.Append((Convert-NodeToMarkdown $child ($Depth + 1)))
    }

    return $builder.ToString()
}

function Convert-NodeToHtml {
    param(
        [Parameter(Mandatory = $true)][object]$Node,
        [int]$Depth = 0
    )

    $headingLevel = [Math]::Min($Depth + 1, 6)
    $key = [Net.WebUtility]::HtmlEncode([string]$Node.key)
    $title = [Net.WebUtility]::HtmlEncode([string]$Node.title)
    $issueType = [Net.WebUtility]::HtmlEncode([string]$Node.issueType)
    $status = [Net.WebUtility]::HtmlEncode([string]$Node.status)
    $assignee = [Net.WebUtility]::HtmlEncode([string]$Node.assignee)
    $priority = [Net.WebUtility]::HtmlEncode([string]$Node.priority)
    $url = [Net.WebUtility]::HtmlEncode([string]$Node.url)

    $descriptionText = [string]$Node.description
    if ([string]::IsNullOrWhiteSpace($descriptionText)) {
        $descriptionText = "(No description)"
    }
    $description = [Net.WebUtility]::HtmlEncode($descriptionText)
    $description = $description -replace "`r?`n", "<br>"

    $priorityRow = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$Node.priority)) {
        $priorityRow = "<dt>Priority</dt><dd>$priority</dd>"
    }

    $childrenHtml = ""
    foreach ($child in @($Node.children)) {
        $childrenHtml += Convert-NodeToHtml $child ($Depth + 1)
    }

    return @"
<section class="issue depth-$Depth">
  <h$headingLevel><a href="$url">$key - $title</a></h$headingLevel>
  <dl>
    <dt>Type</dt><dd>$issueType</dd>
    <dt>Status</dt><dd>$status</dd>
    <dt>Assignee</dt><dd>$assignee</dd>
    $priorityRow
  </dl>
  <h4>Description</h4>
  <div class="description">$description</div>
  <div class="children">$childrenHtml</div>
</section>
"@
}

Write-Host "Testing authentication and exporting issue tree..."
try {
    $tree = Get-IssueTree $RootIssue
}
catch {
    if ($_.Exception.Message -match "401") {
        throw "Authentication failed (401). Check that -Email and the API token are correct.`n$($_.Exception.Message)"
    }
    if ($_.Exception.Message -match "404") {
        throw "Issue '$RootIssue' was not found, or your account does not have permission to view it.`n$($_.Exception.Message)"
    }
    throw
}

if ($null -eq $tree) {
    throw "No issue data was returned for $RootIssue."
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$absoluteOutputDirectory = (Resolve-Path $OutputDirectory).Path
$baseName = $RootIssue.Replace("/", "-").Replace("\", "-")

$markdown = Convert-NodeToMarkdown $tree
$json = $tree | ConvertTo-Json -Depth 50
$htmlTree = Convert-NodeToHtml $tree
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$([Net.WebUtility]::HtmlEncode($RootIssue)) Jira export</title>
  <style>
    body { max-width: 1100px; margin: 40px auto; padding: 0 24px; font-family: Arial, sans-serif; line-height: 1.6; color: #172b4d; }
    a { color: #0c66e4; text-decoration: none; }
    a:hover { text-decoration: underline; }
    .issue { border-left: 4px solid #dfe1e6; margin: 24px 0; padding: 4px 0 4px 20px; }
    .children { margin-left: 18px; }
    dl { display: grid; grid-template-columns: 100px 1fr; gap: 4px 12px; }
    dt { font-weight: 700; }
    dd { margin: 0; }
    .description { white-space: normal; background: #f7f8f9; border-radius: 8px; padding: 16px; }
  </style>
</head>
<body>
$htmlTree
</body>
</html>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$mdPath = Join-Path $absoluteOutputDirectory "$baseName.md"
$htmlPath = Join-Path $absoluteOutputDirectory "$baseName.html"
$jsonPath = Join-Path $absoluteOutputDirectory "$baseName.json"

[IO.File]::WriteAllText($mdPath, $markdown, $utf8NoBom)
[IO.File]::WriteAllText($htmlPath, $html, $utf8NoBom)
[IO.File]::WriteAllText($jsonPath, $json, $utf8NoBom)

Write-Host ""
Write-Host "Export complete:"
Write-Host "  Markdown: $mdPath"
Write-Host "  HTML:     $htmlPath"
Write-Host "  JSON:     $jsonPath"
