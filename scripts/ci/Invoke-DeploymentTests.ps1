[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateJson,

    [Parameter(Mandatory = $true)]
    [string]$ModulePath,

    [Parameter(Mandatory = $true)]
    [string]$ReportDirectory,

    [ValidateRange(1, 3)]
    [int]$MaxAttempts = 3,

    [ValidateRange(1, 30)]
    [int]$WatchdogIntervalSeconds = 5,

    [ValidateRange(1, 120)]
    [int]$McpTimeoutSeconds = 60,

    [ValidateRange(10, 600)]
    [int]$ProcessTimeoutSeconds = 600
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timer = [System.Diagnostics.Stopwatch]::StartNew()

$events = [System.Collections.Generic.List[object]]::new()

$status = "ERROR"
$stage = "Initialization"
$failure = $null
$backupRestored = $false
$watchdogVerified = $false
$recoveryVerified = $false
$idempotenceVerified = $false
$configurationPreserved = $false
$integrationVerified = $false
$verifiedVersions = $null

$workDir = $null
$configPath = $null
$backupPath = $null
$oldEnvironment = @{}


function Write-CiJson {
    param(
        [string]$Path,
        [object]$Data
    )

    $Data |
        ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $Path -Encoding utf8
}


function Invoke-CiProcess {
    param(
        [string]$Name,
        [string]$Command,
        [int]$TimeoutSeconds
    )

    $remaining = [int][Math]::Floor(
        $ProcessTimeoutSeconds -
        $timer.Elapsed.TotalSeconds
    )

    if ($remaining -le 0) {
        throw "Global process time budget exhausted."
    }

    $limit = [Math]::Min(
        $remaining,
        $TimeoutSeconds
    )

    $processTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($Command)
    )

    $stdout = Join-Path $workDir "$Name.stdout.log"
    $stderr = Join-Path $workDir "$Name.stderr.log"
    $stdin = Join-Path $workDir "empty-input.txt"

    [IO.File]::WriteAllText($stdin, "")

    $process = Start-Process `
        -FilePath (Join-Path $PSHOME "powershell.exe") `
        -ArgumentList @(
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-EncodedCommand",
            $encoded
        ) `
        -WorkingDirectory $workDir `
        -RedirectStandardInput $stdin `
        -RedirectStandardOutput $stdout `
        -RedirectStandardError $stderr `
        -NoNewWindow `
        -PassThru

    $timedOut = $false
    $terminated = $false
    $exitCode = $null

    try {
        # Keep the native handle before a fast child exits.
        $handle = $process.Handle

        if (
            $null -eq $handle -or
            $handle -eq [IntPtr]::Zero
        ) {
            throw "Unable to retain the test process handle."
        }

        while (-not $process.HasExited) {

            $remainingMs = [int][Math]::Max(
                0,
                ($limit * 1000) -
                $processTimer.ElapsedMilliseconds
            )

            if ($remainingMs -le 0) {
                $timedOut = $true
                break
            }

            $waitMs = [int][Math]::Min(
                $WatchdogIntervalSeconds * 1000,
                $remainingMs
            )

            if ($process.WaitForExit($waitMs)) {
                break
            }
        }

        if (-not $process.HasExited) {

            $timedOut = $true

            # Stop only the process tree started by this test.

            & "$env:SystemRoot\System32\taskkill.exe" `
                /PID $process.Id /T /F | Out-Null

            if (-not $process.WaitForExit(5000)) {
                throw "Unable to terminate the test process."
            }

            $terminated = $true
        }

        $exitCode = $process.ExitCode
    }
    finally {
        try {
            if (-not $process.HasExited) {

                & "$env:SystemRoot\System32\taskkill.exe" `
                    /PID $process.Id /T /F | Out-Null

                $terminated = $process.WaitForExit(5000)
            }
        }
        finally {
            $processTimer.Stop()

            $events.Add([ordered]@{
                name = $Name
                processId = $process.Id
                timeoutSeconds = $limit
                timedOut = $timedOut
                terminated = $terminated
                exitCode = $exitCode
                durationSeconds = [Math]::Round(
                    $processTimer.Elapsed.TotalSeconds, 3
                )
            })

            $process.Dispose()
        }
    }

    $exitLabel = if ($null -eq $exitCode) {
        "MISSING"
    }
    else {
        [string]$exitCode
    }

    Write-Information -InformationAction Continue -MessageData (
        "[PROCESS] {0}: timeout={1}; terminated={2}; exitCode={3}" -f
        $Name, $timedOut, $terminated, $exitLabel
    )

    return [PSCustomObject]@{
        timedOut = $timedOut
        terminated = $terminated
        exitCode = $exitCode
    }
}


function Assert-CiProcessResult {
    param(
        [object]$Result,
        [string]$Name
    )

    if ($null -eq $Result) {
        throw "$Name returned no process result."
    }

    if ($Result.timedOut) {
        throw "$Name exceeded its time limit."
    }

    if ($Result.terminated) {
        throw "$Name was forcibly terminated."
    }

    if ($null -eq $Result.exitCode) {
        throw "$Name returned no exit code."
    }

    if ($Result.exitCode -isnot [int]) {
        throw "$Name returned an invalid exit code."
    }

    if ($Result.exitCode -ne 0) {
        throw "$Name failed with exit code $($Result.exitCode)."
    }
}


# Restrict this deployment test to the intended CI environment.

if (
    $env:GITHUB_ACTIONS -ne "true" -or
    $env:RUNNER_ENVIRONMENT -ne "github-hosted" -or
    $env:RUNNER_OS -ne "Windows" -or
    -not $env:RUNNER_TEMP
) {
    throw "This deployment test requires a hosted Windows CI runner."
}

if ($PSVersionTable.PSEdition -ne "Desktop") {
    throw "Windows PowerShell 5.1 is required by this workflow."
}

New-Item `
    -ItemType Directory `
    -Path $ReportDirectory `
    -Force | Out-Null

try {
    Write-Output "=== Deployment integration tests ==="
    Write-Output "UTC: $([DateTime]::UtcNow.ToString('o'))"
    Write-Output "PowerShell: $($PSVersionTable.PSVersion)"

    # Validate the candidate dependency snapshot.

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
            $expectedNames $actualNames -CaseSensitive)
    ) {
        throw "Invalid candidate dependency list."
    }

    foreach ($name in $expectedNames) {

        if (
            $candidate.$name -isnot [string] -or
            $candidate.$name -notmatch '^\d+(?:\.\d+)+$'
        ) {
            throw "Invalid candidate version: $name"
        }
    }

    $repositoryRoot = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot "..\..")
    )

    $installer = Join-Path `
        $repositoryRoot "scripts\install-windows.ps1"

    $testFile = Join-Path `
        $repositoryRoot "tests\integration\Deployment.Tests.ps1"

    $pesterManifest = Join-Path `
        $ModulePath "Pester\5.7.1\Pester.psd1"

    foreach ($file in @(
        $installer,
        $testFile,
        $pesterManifest
    )) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Required integration file missing."
        }
    }

    # Create an isolated test directory.

    $workDir = Join-Path $env:RUNNER_TEMP (
        "deployment-test-" + [Guid]::NewGuid().ToString("N")
    )

    $codexHome = Join-Path $workDir "codex-home"

    New-Item `
        -ItemType Directory `
        -Path $codexHome `
        -Force | Out-Null

    $configPath = Join-Path $codexHome "config.toml"
    $backupPath = Join-Path $workDir "config.toml.backup"
    $evidencePath = Join-Path $workDir "integration-evidence.json"

    $xmlPath = Join-Path `
        $ReportDirectory "integration-tests.xml"

    $fixture = "# CI configuration preservation test`n"

    [IO.File]::WriteAllText(
        $configPath,
        $fixture,
        [Text.UTF8Encoding]::new($false)
    )

    Copy-Item `
        -LiteralPath $configPath `
        -Destination $backupPath

    $originalHash = (
        Get-FileHash -LiteralPath $backupPath -Algorithm SHA256
    ).Hash

    # Pass isolated configuration and test parameters to children.

    $environment = @{
        CODEX_HOME = $codexHome
        CI_DEPLOY_INSTALLER = $installer
        CI_DEPLOY_TEST_FILE = $testFile
        CI_DEPLOY_PESTER = $pesterManifest
        CI_DEPLOY_CANDIDATE = $CandidateJson
        CI_DEPLOY_CONFIG = $configPath
        CI_DEPLOY_EVIDENCE = $evidencePath
        CI_DEPLOY_XML = $xmlPath
        CI_DEPLOY_REPOSITORY = $repositoryRoot
        CI_DEPLOY_MCP_TIMEOUT = [string]$McpTimeoutSeconds
        CI_DEPLOY_MAX_ATTEMPTS = [string]$MaxAttempts
    }

    foreach ($key in $environment.Keys) {

        $oldEnvironment[$key] = [Environment]::GetEnvironmentVariable(
            $key, "Process"
        )

        [Environment]::SetEnvironmentVariable(
            $key,
            [string]$environment[$key],
            "Process"
        )
    }

    # Verify the watchdog with an intentionally blocked child.

    $stage = "Watchdog self-test"

    $blockedProcess = Invoke-CiProcess `
        -Name "watchdog-self-test" `
        -Command "Start-Sleep -Seconds 30" `
        -TimeoutSeconds 2

    if (
        -not $blockedProcess.timedOut -or
        -not $blockedProcess.terminated
    ) {
        throw "Watchdog self-test failed."
    }

    $watchdogVerified = $true

    Write-Output "[SUCCESS] Watchdog detected a blocked process."

    # Verify that a new process can run after termination.

    $stage = "Recovery self-test"

    $recovery = Invoke-CiProcess `
        -Name "recovery-self-test" `
        -Command "exit 0" `
        -TimeoutSeconds 15

    Assert-CiProcessResult `
        -Result $recovery `
        -Name "Recovery self-test"

    $stage = "Recovery exit-code self-test"

    $nonZeroResult = Invoke-CiProcess `
        -Name "recovery-nonzero-self-test" `
        -Command "exit 7" `
        -TimeoutSeconds 15

    if (
        $nonZeroResult.timedOut -or
        $nonZeroResult.terminated -or
        $nonZeroResult.exitCode -isnot [int] -or
        $nonZeroResult.exitCode -ne 7
    ) {
        throw "Non-zero exit code was not preserved."
    }

    try {
        Assert-CiProcessResult `
            -Result $nonZeroResult `
            -Name "Non-zero exit self-test"

        throw "Non-zero exit code was incorrectly accepted."
    }
    catch {
        if (
            $_.Exception.Message -cne
            "Non-zero exit self-test failed with exit code 7."
        ) {
            throw
        }
    }

    $recoveryVerified = $true

    Write-Output "[RECOVERED] Process execution restored."

    # First actual installation.

    $stage = "First installation"

    $installCommand = @'
$ErrorActionPreference = "Stop"
& $env:CI_DEPLOY_INSTALLER -NoLaunch
exit $LASTEXITCODE
'@

    $firstInstall = Invoke-CiProcess `
        -Name "installation-first" `
        -Command $installCommand `
        -TimeoutSeconds $ProcessTimeoutSeconds

    Assert-CiProcessResult `
        -Result $firstInstall `
        -Name "First installation"

    Write-Output "[SUCCESS] First installation completed."

    # Check that the existing configuration was preserved.

    $stage = "Configuration preservation"

    $installedConfig = [IO.File]::ReadAllText($configPath)

    if (-not $installedConfig.StartsWith(
        $fixture,
        [StringComparison]::Ordinal
    )) {
        throw "Existing configuration was modified unexpectedly."
    }

    $configurationPreserved = $true

    $firstHash = (
        Get-FileHash -LiteralPath $configPath -Algorithm SHA256
    ).Hash

    # Second installation to verify configuration idempotence.

    $stage = "Second installation"

    $secondInstall = Invoke-CiProcess `
        -Name "installation-second" `
        -Command $installCommand `
        -TimeoutSeconds $ProcessTimeoutSeconds

    Assert-CiProcessResult `
        -Result $secondInstall `
        -Name "Second installation"

    $secondHash = (
        Get-FileHash -LiteralPath $configPath -Algorithm SHA256
    ).Hash

    if ($firstHash -cne $secondHash) {
        throw "Configuration idempotence check failed."
    }

    $idempotenceVerified = $true

    Write-Output "[SUCCESS] Configuration idempotence verified."

    # Run the real Pester integration suite.

    $stage = "Pester integration tests"

    $testCommand = @'
$ErrorActionPreference = "Stop"

Import-Module $env:CI_DEPLOY_PESTER -Force

$container = New-PesterContainer `
    -Path $env:CI_DEPLOY_TEST_FILE `
    -Data @{
        CandidateJson = $env:CI_DEPLOY_CANDIDATE
        ConfigPath = $env:CI_DEPLOY_CONFIG
        EvidencePath = $env:CI_DEPLOY_EVIDENCE
        RepositoryRoot = $env:CI_DEPLOY_REPOSITORY
        McpTimeoutSeconds = [int]$env:CI_DEPLOY_MCP_TIMEOUT
        MaxAttempts = [int]$env:CI_DEPLOY_MAX_ATTEMPTS
    }

$configuration = New-PesterConfiguration

$configuration.Run.Container = @($container)
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = "Detailed"

$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputFormat = "NUnitXml"
$configuration.TestResult.OutputPath = $env:CI_DEPLOY_XML

$result = Invoke-Pester -Configuration $configuration

if (
    $result.Result -ne "Passed" -or
    $result.TotalCount -eq 0 -or
    $result.PassedCount -ne $result.TotalCount
) {
    exit 1
}

exit 0
'@

    $testResult = Invoke-CiProcess `
        -Name "pester-integration" `
        -Command $testCommand `
        -TimeoutSeconds $ProcessTimeoutSeconds

    Assert-CiProcessResult `
        -Result $testResult `
        -Name "Pester integration tests"

    # Require evidence from actual integration tests.

    $stage = "Integration evidence"

    foreach ($file in @($evidencePath, $xmlPath)) {

        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Required integration evidence missing."
        }

        if ((Get-Item -LiteralPath $file).Length -eq 0) {
            throw "Integration evidence is empty."
        }
    }

    $evidence = Get-Content `
        -LiteralPath $evidencePath `
        -Raw | ConvertFrom-Json

    foreach ($check in @(
        "addonActive",
        "mcpReadOnlyVerified",
        "zeroClickVerified"
    )) {
        if (
            $evidence.$check -isnot [bool] -or
            $evidence.$check -ne $true
        ) {
            throw "Integration requirement not verified: $check"
        }
    }

    # Compare independently observed installed versions.

    $stage = "Installed version verification"

    $observed = $evidence.versions

    $observedNames = @(
        $observed.PSObject.Properties.Name
    )

    if (
        $observedNames.Count -ne $expectedNames.Count -or
        (Compare-Object `
            $expectedNames $observedNames -CaseSensitive)
    ) {
        throw "Observed dependency list mismatch."
    }

    $verifiedVersions = [ordered]@{}

    foreach ($name in $expectedNames) {

        if (
            $observed.$name -isnot [string] -or
            $observed.$name -cne $candidate.$name
        ) {
            throw "Installed version mismatch: $name"
        }

        $verifiedVersions[$name] = $observed.$name

        Write-Output (
            "[VERIFIED] $name $($observed.$name)"
        )
    }

    $integrationVerified = $true
    $status = "SUCCESS"
}
catch {
    $status = "ERROR"

    $failure = @{
        stage = $stage
        errorType = $_.Exception.GetType().Name
        scriptLine = $_.InvocationInfo.ScriptLineNumber
    }

    Write-Warning (
        "Deployment test failed at stage: {0}; type: {1}; line: {2}" -f
        $failure.stage, $failure.errorType, $failure.scriptLine
    )
}
finally {

    # Restore only the isolated test configuration.

    if (
        $backupPath -and
        (Test-Path -LiteralPath $backupPath -PathType Leaf)
    ) {
        try {
            Copy-Item `
                -LiteralPath $backupPath `
                -Destination $configPath `
                -Force

            $restoredHash = (
                Get-FileHash `
                    -LiteralPath $configPath `
                    -Algorithm SHA256
            ).Hash

            if ($restoredHash -cne $originalHash) {
                throw "Configuration restoration mismatch."
            }

            $backupRestored = $true

            Write-Output "[SUCCESS] Test configuration restored."
        }
        catch {
            $status = "ERROR"

            $failure = @{
                stage = "Configuration restoration"
                errorType = $_.Exception.GetType().Name
            }
        }
    }

    foreach ($key in $oldEnvironment.Keys) {

        [Environment]::SetEnvironmentVariable(
            $key,
            $oldEnvironment[$key],
            "Process"
        )
    }

    $timer.Stop()

    # Watchdog report.

    $watchdogReport = [ordered]@{
        schemaVersion = 1
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        intervalSeconds = $WatchdogIntervalSeconds
        processBudgetSeconds = $ProcessTimeoutSeconds
        mcpTimeoutSeconds = $McpTimeoutSeconds
        watchdogVerified = $watchdogVerified
        recoverySelfTestVerified = $recoveryVerified
        events = $events.ToArray()
    }

    Write-CiJson `
        -Path (Join-Path $ReportDirectory "watchdog.json") `
        -Data $watchdogReport

    # Deployment report.

    $deploymentReport = [ordered]@{
        schemaVersion = 1
        timestampUtc = [DateTime]::UtcNow.ToString("o")
        status = $status
        durationSeconds = [Math]::Round(
            $timer.Elapsed.TotalSeconds, 3
        )
        watchdogVerified = $watchdogVerified
        recoverySelfTestVerified = $recoveryVerified
        configurationPreserved = $configurationPreserved
        configurationIdempotenceVerified = $idempotenceVerified
        backupRestored = $backupRestored
        integrationVerified = $integrationVerified
        maxMcpAttempts = $MaxAttempts
        failure = $failure
    }

    Write-CiJson `
        -Path (Join-Path $ReportDirectory "deployment.json") `
        -Data $deploymentReport

    if ($env:GITHUB_STEP_SUMMARY) {

        @(
            "## Deployment integration"
            ""
            "- Status: $status"
            "- Watchdog verified: $watchdogVerified"
            "- Recovery self-test: $recoveryVerified"
            "- Configuration preserved: $configurationPreserved"
            "- Idempotence: $idempotenceVerified"
            "- Backup restored: $backupRestored"
            "- Integration verified: $integrationVerified"
            "- Duration: $($deploymentReport.durationSeconds) seconds"
        ) | Out-File `
            -FilePath $env:GITHUB_STEP_SUMMARY `
            -Append `
            -Encoding utf8
    }
}

if ($status -ne "SUCCESS" -or -not $backupRestored) {
    throw "Deployment integration validation failed."
}

# Publish verified versions only after successful validation.

Write-CiJson `
    -Path (Join-Path $ReportDirectory "verified-versions.json") `
    -Data $verifiedVersions

Write-Output "[SUCCESS] Deployment integration validated."
