[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateJson,

    [Parameter(Mandatory = $true)]
    [string]$ReportDirectory
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$maxAttempts = 3

$apiUrl = "https://api.github.com/advisories"

$results = [System.Collections.Generic.List[object]]::new()
$findings = [System.Collections.Generic.List[object]]::new()
$scanErrors = [System.Collections.Generic.List[object]]::new()
$coverageGaps = [System.Collections.Generic.List[object]]::new()

$headers = @{
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent" = "Maison-Domotique-CI/1.0"
}

$blocking = $false

function Get-CiAdvisoryPage {
    param(
        [string]$Url
    )

    $uri = [Uri]$Url

    if (
        $uri.Scheme -cne "https" -or
        $uri.Host -cne "api.github.com" -or
        $uri.AbsolutePath -cne "/advisories" -or
        $uri.Port -ne 443 -or
        $uri.UserInfo
    ) {
        throw "Unauthorized advisory URL."
    }

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            return Invoke-WebRequest `
                -Uri $uri `
                -Headers $headers `
                -UseBasicParsing `
                -TimeoutSec 8 `
                -MaximumRedirection 0 `
                -ErrorAction Stop
        }
        catch {
            $exception = $_.Exception
            $statusCode = 0

            if (
                $exception.PSObject.Properties["Response"] -and
                $null -ne $exception.Response
            ) {
                $statusCode = [int]$exception.Response.StatusCode
            }

            $transient = (
                $statusCode -in @(408, 429) -or
                ($statusCode -ge 500 -and $statusCode -lt 600) -or
                (
                    $statusCode -eq 0 -and
                    (
                        $exception -is [System.Net.Http.HttpRequestException] -or
                        $exception -is [System.TimeoutException] -or
                        $exception -is [System.OperationCanceledException] -or
                        $exception -is [System.Net.WebException]
                    )
                )
            )

            if (-not $transient -or $attempt -ge $maxAttempts) {
                throw
            }

            $delay = [int][Math]::Pow(2, $attempt)

            Write-Warning (
                "Advisory request failed. " +
                "Attempt $attempt/$maxAttempts. " +
                "Retry in $delay seconds."
            )

            Start-Sleep -Seconds $delay
        }
    }

    throw "Advisory query failed."
}


function Get-CiAdvisories {
    param(
        [string]$Ecosystem,
        [string]$Package,
        [string]$Version,
        [string]$AdvisoryType
    )

    $affects = [Uri]::EscapeDataString(
        "$Package@$Version"
    )

    $url = (
        "${apiUrl}?ecosystem=$Ecosystem" +
        "&affects=$affects" +
        "&type=$AdvisoryType" +
        "&is_withdrawn=false" +
        "&per_page=100"
    )

    $pageCount = 0
    $seenPages = @{}

    while ($url) {
        $pageCount++

        if ($pageCount -gt 10) {
            throw "Advisory pagination limit exceeded."
        }

        if ($seenPages.ContainsKey($url)) {
            throw "Advisory pagination loop detected."
        }

        $seenPages[$url] = $true

        $response = Get-CiAdvisoryPage -Url $url

        $content = [string]$response.Content

        if (
            -not $content.Trim().StartsWith("[") -or
            -not $content.Trim().EndsWith("]")
        ) {
            throw "Invalid advisory response."
        }

        $items = @($content | ConvertFrom-Json)

        foreach ($item in $items) {

            if (
                -not $item.ghsa_id -or
                [string]$item.type -ne $AdvisoryType
            ) {
                throw "Invalid advisory record."
            }

            if (-not $item.withdrawn_at) {
                Write-Output $item
            }
        }

        $linkHeader = $response.Headers["Link"] -join ","

        if ($linkHeader -match '<([^>]+)>\s*;\s*rel="next"') {
            $url = $Matches[1]
        }
        elseif ($linkHeader -match 'rel="next"') {
            throw "Invalid pagination header."
        }
        else {
            $url = $null
        }
    }
}


function Get-CiSeverity {
    param(
        [object]$Advisory
    )

    if ($Advisory.type -eq "malware") {
        return "CRITICAL"
    }

    $severity = ([string]$Advisory.severity).ToUpperInvariant()

    if ($severity -notin @(
        "CRITICAL",
        "HIGH",
        "MEDIUM",
        "LOW"
    )) {
        return "UNKNOWN"
    }

    return $severity
}


try {
    New-Item `
        -ItemType Directory `
        -Path $ReportDirectory `
        -Force | Out-Null

    Write-Output "=== CI dependency security scan ==="
    Write-Output "UTC: $([DateTime]::UtcNow.ToString('o'))"
    Write-Output "PowerShell: $($PSVersionTable.PSVersion)"

    # Validate the candidate snapshot.

    $candidate = $CandidateJson | ConvertFrom-Json

    $expectedNames = @(
        "Blender",
        "Codex",
        "MCP",
        "Git",
        "UV",
        "NodeJS"
    )

    $actualNames = @(
        $candidate.PSObject.Properties.Name
    )

    if (
        $actualNames.Count -ne $expectedNames.Count -or
        (Compare-Object `
            -ReferenceObject $expectedNames `
            -DifferenceObject $actualNames `
            -CaseSensitive)
    ) {
        throw "Candidate dependency list mismatch."
    }

    foreach ($name in $expectedNames) {
        $version = $candidate.$name

        if (
            $version -isnot [string] -or
            $version -notmatch '^\d+(?:\.\d+)+$'
        ) {
            throw "Invalid candidate version: $name"
        }
    }

    # Supported package ecosystems.

    $targets = @(
        @{
            component = "Codex"
            ecosystem = "npm"
            package = "@openai/codex"
            version = $candidate.Codex
        },
        @{
            component = "MCP"
            ecosystem = "pip"
            package = "mcp-for-blender"
            version = $candidate.MCP
        },
        @{
            component = "UV"
            ecosystem = "pip"
            package = "uv"
            version = $candidate.UV
        }
    )

    # Record unsupported or incomplete coverage.

    foreach ($name in @("Blender", "Git", "NodeJS")) {
        $coverageGaps.Add(@{
            component = $name
            version = $candidate.$name
            reason = "Native application advisory source required"
        })
    }

    $coverageGaps.Add(@{
        component = "UV"
        version = $candidate.UV
        reason = "PyPI scan does not verify the WinGet binary"
    })

    foreach ($name in @(
        "PSScriptAnalyzer",
        "Pester",
        "Python",
        "Transitive dependencies",
        "Actual installed versions",
        "Installer signatures and hashes",
        "Unreviewed security advisories"
    )) {
        $coverageGaps.Add(@{
            component = $name
            reason = "Additional security verification required"
        })
    }

    # Scan reviewed vulnerabilities and malware.

    foreach ($target in $targets) {
        $component = $target.component
        $package = $target.package
        $version = $target.version
        $seenAdvisories = @{}

        $componentFindings = 0
        $componentBlocked = $false
        $componentFailed = $false

        Write-Output "Scanning $component $version"

        foreach ($advisoryType in @("reviewed", "malware")) {

            try {
                $advisories = @(
                    Get-CiAdvisories `
                        -Ecosystem $target.ecosystem `
                        -Package $package `
                        -Version $version `
                        -AdvisoryType $advisoryType
                )

                foreach ($advisory in $advisories) {
                    $id = [string]$advisory.ghsa_id

                    if ($seenAdvisories.ContainsKey($id)) {
                        continue
                    }

                    $seenAdvisories[$id] = $true

                    $severity = Get-CiSeverity `
                        -Advisory $advisory

                    $isBlocking = $severity -in @(
                        "CRITICAL",
                        "HIGH",
                        "UNKNOWN"
                    )

                    $componentFindings++

                    if ($isBlocking) {
                        $componentBlocked = $true
                        $blocking = $true
                    }

                    $findings.Add(@{
                        component = $component
                        package = $package
                        version = $version
                        ecosystem = $target.ecosystem
                        ghsa = $id
                        cve = $advisory.cve_id
                        severity = $severity
                        advisoryType = $advisoryType
                        summary = $advisory.summary
                        url = $advisory.html_url
                        blocking = $isBlocking
                    })

                    $message = (
                        "[$severity] $component " +
                        "$version - $id"
                    )

                    if ($severity -eq "MEDIUM") {
                        Write-Warning $message
                    }
                    else {
                        Write-Output $message
                    }
                }
            }
            catch {
                $componentFailed = $true
                $blocking = $true

                $scanErrors.Add(@{
                    component = $component
                    advisoryType = $advisoryType
                    errorType = $_.Exception.GetType().Name
                })

                Write-Warning (
                    "Security source failed: " +
                    "$component / $advisoryType"
                )
            }
        }

        $componentStatus = if ($componentFailed) {
            "SCAN_ERROR"
        }
        elseif ($componentBlocked) {
            "BLOCKED"
        }
        elseif ($componentFindings -gt 0) {
            "FINDINGS"
        }
        else {
            "NO_KNOWN_ADVISORY"
        }

        $results.Add(@{
            component = $component
            package = $package
            version = $version
            ecosystem = $target.ecosystem
            status = $componentStatus
            findings = $componentFindings
        })

        Write-Output "[$componentStatus] $component"
    }
}
catch {
    $blocking = $true

    $scanErrors.Add(@{
        component = "SecurityScan"
        errorType = $_.Exception.GetType().Name
        message = $_.Exception.Message
    })

    Write-Warning "Security scan initialization failed."
}
finally {
    $timer.Stop()

    $critical = @(
        $findings.ToArray() |
            Where-Object { $_.severity -eq "CRITICAL" }
    ).Count

    $high = @(
        $findings.ToArray() |
            Where-Object { $_.severity -eq "HIGH" }
    ).Count

    $medium = @(
        $findings.ToArray() |
            Where-Object { $_.severity -eq "MEDIUM" }
    ).Count

    $low = @(
        $findings.ToArray() |
            Where-Object { $_.severity -eq "LOW" }
    ).Count

    $unknown = @(
        $findings.ToArray() |
            Where-Object { $_.severity -eq "UNKNOWN" }
    ).Count

    $status = if ($scanErrors.Count -gt 0) {
        "SCAN_ERROR"
    }
    elseif ($blocking) {
        "BLOCKED"
    }
    elseif ($coverageGaps.Count -gt 0) {
        "PARTIAL"
    }
    else {
        "COMPLETED"
    }

    $report = [ordered]@{
        schemaVersion = 1
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        status = $status
        blocking = $blocking
        scope = "Candidate package versions"
        source = "GitHub Advisory Database"
        coverageComplete = (
            $coverageGaps.Count -eq 0 -and
            $scanErrors.Count -eq 0
        )
        durationSeconds = [Math]::Round(
            $timer.Elapsed.TotalSeconds, 3
        )
        critical = $critical
        high = $high
        medium = $medium
        low = $low
        unknown = $unknown
        scannedComponents = $results.ToArray()
        findings = $findings.ToArray()
        errors = $scanErrors.ToArray()
        coverageGaps = $coverageGaps.ToArray()
    }

    $reportPath = Join-Path `
        $ReportDirectory "security.json"

    $report |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -LiteralPath $reportPath `
            -Encoding utf8

    $summary = @(
        "## Security scan"
        ""
        "- Status: $status"
        "- Critical: $critical"
        "- High: $high"
        "- Medium: $medium"
        "- Low: $low"
        "- Unknown: $unknown"
        "- Scan errors: $($scanErrors.Count)"
        "- Coverage gaps: $($coverageGaps.Count)"
        "- Blocking: $blocking"
        "- Duration: $($report.durationSeconds) seconds"
    )

    if ($env:GITHUB_STEP_SUMMARY) {
        $summary |
            Out-File `
                -FilePath $env:GITHUB_STEP_SUMMARY `
                -Append `
                -Encoding utf8
    }

    $summary | Write-Output
}

if ($blocking) {
    throw "Security scan blocked the deployment."
}

if ($coverageGaps.Count -gt 0) {
    Write-Warning "Security coverage remains incomplete."
}
