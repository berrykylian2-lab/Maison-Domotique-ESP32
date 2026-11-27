[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ModulePath,

    [Parameter(Mandatory = $true)]
    [string]$LockFile
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$timer = [System.Diagnostics.Stopwatch]::StartNew()
$maxAttempts = 3

function Test-CiModule {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Version
    )

    $manifestPath = Join-Path $Path "$Name.psd1"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }

    try {
        $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath

        if ([string]$manifest.ModuleVersion -cne $Version) {
            return $false
        }

        if ($manifest.PrivateData.PSData.Prerelease) {
            return $false
        }

        if ($manifest.RequiredModules) {
            return $false
        }

        if (-not $manifest.RootModule) {
            return $false
        }

        if ([IO.Path]::IsPathRooted($manifest.RootModule)) {
            return $false
        }

        $root = [IO.Path]::GetFullPath($Path).TrimEnd(
            [IO.Path]::DirectorySeparatorChar
        )

        $rootModule = [IO.Path]::GetFullPath(
            (Join-Path $root $manifest.RootModule)
        )

        $prefix = $root + [IO.Path]::DirectorySeparatorChar

        if (-not $rootModule.StartsWith(
            $prefix,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            return $false
        }

        return (
            Test-Path -LiteralPath $rootModule -PathType Leaf
        )
    }
    catch {
        Write-Verbose $_.Exception.Message
        return $false
    }
}


function Test-TransientError {
    param(
        [System.Exception]$Exception
    )

    $current = $Exception

    while ($null -ne $current) {

        if ($current -is [System.TimeoutException]) {
            return $true
        }

        if ($current -is [System.Net.WebException]) {

            if ($current.Status -in @(
                "Timeout",
                "ConnectFailure",
                "ConnectionClosed",
                "ReceiveFailure",
                "SendFailure",
                "NameResolutionFailure"
            )) {
                return $true
            }
        }

        $statusCode = $null

        if ($current.PSObject.Properties["StatusCode"]) {
            $statusCode = $current.StatusCode
        }
        elseif (
            $current.PSObject.Properties["Response"] -and
            $null -ne $current.Response -and
            $current.Response.PSObject.Properties["StatusCode"]
        ) {
            $statusCode = $current.Response.StatusCode
        }

        if ($null -ne $statusCode) {
            $code = [int]$statusCode

            if (
                $code -in @(408, 429) -or
                ($code -ge 500 -and $code -lt 600)
            ) {
                return $true
            }
        }

        $current = $current.InnerException
    }

    return $false
}


try {
    Write-Output "=== CI tools initialization ==="
    Write-Output "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Output "UTC: $([DateTime]::UtcNow.ToString('o'))"

    # Validate lock file.

    if (-not (Test-Path -LiteralPath $LockFile -PathType Leaf)) {
        throw "Lock file missing: $LockFile"
    }

    $lock = Get-Content -LiteralPath $LockFile -Raw |
        ConvertFrom-Json

    if ($lock.schemaVersion -ne 1) {
        throw "Unsupported lock file schema."
    }

    $galleryUrl = "https://www.powershellgallery.com/api/v2"

    if (
        $lock.repository.name -cne "PSGallery" -or
        $lock.repository.url -cne $galleryUrl
    ) {
        throw "Unauthorized module repository."
    }

    if (
        $lock.policy.exactVersions -ne $true -or
        $lock.policy.allowPrerelease -ne $false -or
        $lock.policy.allowUnlistedModules -ne $false -or
        $lock.policy.autoUpgrade -ne $false -or
        $lock.policy.failOnVersionMismatch -ne $true
    ) {
        throw "Invalid module security policy."
    }

    $expectedNames = @("PSScriptAnalyzer", "Pester")
    $actualNames = @($lock.modules | ForEach-Object {
        $_.name
    })

    if (
        $actualNames.Count -ne $expectedNames.Count -or
        (Compare-Object $expectedNames $actualNames)
    ) {
        throw "Unexpected module list."
    }

    foreach ($module in $lock.modules) {
        if (
            $module.version -notmatch '^\d+\.\d+\.\d+$' -or
            $module.required -ne $true
        ) {
            throw "Invalid module declaration: $($module.name)"
        }
    }

    # Enable TLS 1.2 on Windows PowerShell 5.1.

    if ($PSVersionTable.PSEdition -eq "Desktop") {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor
            [Net.SecurityProtocolType]::Tls12
    }

    # Prepare the temporary module directory.

    $ModulePath = [IO.Path]::GetFullPath($ModulePath)

    New-Item -ItemType Directory -Path $ModulePath -Force | Out-Null

    # Verify the registered repository.

    $repository = Get-PSRepository -Name PSGallery -ErrorAction Stop

    if ($repository.SourceLocation.TrimEnd("/") -cne $galleryUrl) {
        throw "PSGallery source URL mismatch."
    }

    # Prepare NuGet without administrator rights.

    $provider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Version -ge [version]"2.8.5.201"
        } |
        Select-Object -First 1

    if (-not $provider) {
        Install-PackageProvider -Name NuGet -MinimumVersion "2.8.5.201" -Scope CurrentUser -Force -Confirm:$false -ErrorAction Stop | Out-Null
    }

    foreach ($module in $lock.modules) {

        $name = [string]$module.name
        $version = [string]$module.version

        $moduleDirectory = Join-Path $ModulePath $name
        $target = Join-Path $moduleDirectory $version

        Write-Output "Checking $name $version"

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

            $staging = Join-Path $ModulePath (
                ".staging-" + [Guid]::NewGuid().ToString("N")
            )

            try {
                # Check that the exact stable version is discoverable.

                $available = Find-Module -Name $name -Repository PSGallery -AllVersions -ErrorAction Stop |
                    Where-Object {
                        $_.Name -ceq $name -and
                        [string]$_.Version -ceq $version
                    } |
                    Select-Object -First 1

                if (-not $available) {
                    throw "Locked version unavailable: $name $version"
                }

                # Reuse an existing valid module.

                if (Test-CiModule -Path $target -Name $name -Version $version) {

                    Write-Output "[CACHE HIT] $name $version"
                    break
                }

                # Download into an isolated staging directory.

                New-Item -ItemType Directory -Path $staging -Force | Out-Null

                Write-Output "[DOWNLOAD] $name $version"

                Save-Module -Name $name -RequiredVersion $version -Repository PSGallery -Path $staging -Force -Confirm:$false -ErrorAction Stop

                $stagedModule = Join-Path (Join-Path $staging $name) $version

                if (-not (Test-CiModule -Path $stagedModule -Name $name -Version $version)) {

                    throw "Downloaded module validation failed: $name"
                }

                $downloadedNames = @(
                    Get-ChildItem -LiteralPath $staging -Directory |
                    Select-Object -ExpandProperty Name
                )

                if (
                    $downloadedNames.Count -ne 1 -or
                    $downloadedNames[0] -cne $name
                ) {
                    throw "Unexpected module dependencies."
                }

                New-Item -ItemType Directory -Path $moduleDirectory -Force | Out-Null

                # Replace only the invalid version directory.

                if (Test-Path -LiteralPath $target) {
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                }

                Move-Item -LiteralPath $stagedModule -Destination $target -ErrorAction Stop

                if (-not (Test-CiModule -Path $target -Name $name -Version $version)) {

                    throw "Final module validation failed: $name"
                }

                Write-Output "[SUCCESS] $name $version"
                break
            }
            catch {
                $transient = Test-TransientError -Exception $_.Exception

                if (-not $transient -or $attempt -ge $maxAttempts) {
                    throw
                }

                $delay = [int][Math]::Pow(2, $attempt - 1)

                Write-Warning (
                    "Temporary network failure. " +
                    "Attempt $attempt/$maxAttempts. " +
                    "Retry in $delay seconds."
                )

                Start-Sleep -Seconds $delay
            }
            finally {
                if (Test-Path -LiteralPath $staging) {
                    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction Stop
                }
            }
        }
    }

    Write-Output "[SUCCESS] All locked CI tools are ready."
}
catch {
    Write-Output "[ERROR] $($_.Exception.Message)"
    throw
}
finally {
    $timer.Stop()

    Write-Output (
        "Duration: {0:N2} seconds" -f
        $timer.Elapsed.TotalSeconds
    )
}
