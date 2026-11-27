param(
    [Parameter(Mandatory = $true)]
    [string]$CandidateJson,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$EvidencePath,

    [Parameter(Mandatory = $true)]
    [string]$RepositoryRoot,

    [ValidateRange(1, 120)]
    [int]$McpTimeoutSeconds = 60,

    [ValidateRange(1, 3)]
    [int]$MaxAttempts = 3
)

Describe "Windows deployment integration" -ForEach @(
    @{
        CandidateJson = $CandidateJson
        ConfigPath = $ConfigPath
        EvidencePath = $EvidencePath
        RepositoryRoot = $RepositoryRoot
        McpTimeoutSeconds = $McpTimeoutSeconds
        MaxAttempts = $MaxAttempts

        state = @{
            versions = @{}
            paths = @{}
            configurationVerified = $false
            codexConfigurationVerified = $false
            addonActive = $false
            mcpReadOnlyVerified = $false
            reconnectionVerified = $false
            launcherVerified = $false
            checks = @{}
            originalPath = $null
            originalOffline = $null
            environmentCaptured = $false
        }
    }
) {

    BeforeAll {

        $ErrorActionPreference = "Stop"

        # Restrict actual integration tests to hosted CI.

        if (
            $env:GITHUB_ACTIONS -ne "true" -or
            $env:RUNNER_ENVIRONMENT -ne "github-hosted" -or
            $env:RUNNER_OS -ne "Windows"
        ) {
            throw "Hosted Windows CI runner required."
        }

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

        $state.originalPath = $env:Path
        $state.originalOffline = $env:UV_OFFLINE
        $state.environmentCaptured = $true

        # Refresh PATH after installation in separate processes.

        $paths = @(
            $env:Path
            [Environment]::GetEnvironmentVariable(
                "Path", "Machine"
            )
            [Environment]::GetEnvironmentVariable(
                "Path", "User"
            )
            "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
            "$HOME\.local\bin"
            "$env:APPDATA\npm"
            "$env:ProgramFiles\Git\cmd"
            "$env:ProgramFiles\nodejs"
        )

        $env:Path = (
            ($paths -join ";") -split ";" |
                Where-Object { $_ } |
                Select-Object -Unique
        ) -join ";"

        # Verification must not download newer packages.

        $env:UV_OFFLINE = "1"

        $probePath = Join-Path `
            $TestDrive "integration-probe.py"

        function Get-CiExecutable {
            param(
                [string[]]$Names
            )

            foreach ($name in $Names) {

                $command = Get-Command `
                    -Name $name `
                    -CommandType Application `
                    -ErrorAction SilentlyContinue |
                    Select-Object -First 1

                if ($command) {
                    return $command.Source
                }
            }

            throw (
                "Executable unavailable: " +
                ($Names -join ", ")
            )
        }


        function Get-CiBlender {

            $command = Get-Command `
                -Name "blender.exe" `
                -CommandType Application `
                -ErrorAction SilentlyContinue |
                Select-Object -First 1

            if ($command) {
                return $command.Source
            }

            $roots = @(
                "$env:ProgramFiles\Blender Foundation"
                "$env:LOCALAPPDATA\Programs\Blender Foundation"
                "$env:LOCALAPPDATA\Programs\Blender"
            )

            foreach ($root in $roots) {

                if (Test-Path -LiteralPath $root) {

                    $found = Get-ChildItem `
                        -LiteralPath $root `
                        -Filter "blender.exe" `
                        -File `
                        -Recurse |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 1

                    if ($found) {
                        return $found.FullName
                    }
                }
            }

            throw "Blender executable unavailable."
        }


        function Invoke-CiNative {
            param(
                [string]$FilePath,

                [string[]]$Arguments
            )

            $output = @(
                & $FilePath @Arguments
            )

            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {

                throw (
                    "Native command failed: " +
                    "exit code $exitCode"
                )
            }

            return ($output -join "`n")
        }


        function Get-CiVersion {
            param(
                [string]$FilePath,

                [string]$Pattern
            )

            $output = Invoke-CiNative `
                -FilePath $FilePath `
                -Arguments @("--version")

            $match = [regex]::Match(
                $output,
                $Pattern
            )

            if (-not $match.Success) {
                throw "Version detection failed."
            }

            return $match.Groups[1].Value
        }


        # Python probe:
        # - Parse actual Codex configuration with tomllib.
        # - Read the resolved MCP package metadata.
        # - Launch Blender without opening a project.
        # - Never enable the addon from the test.
        # - Connect using the configured MCP command.
        # - Query only read-only addon status.
        # - Verify a second independent MCP session.

        $pythonProbe = @'
import asyncio
import importlib.metadata
import ipaddress
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import time
import tomllib

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


config_path = pathlib.Path(sys.argv[1])
blender_path = pathlib.Path(sys.argv[2])
uvx_path = pathlib.Path(sys.argv[3])
expected_blender = sys.argv[4]
expected_mcp = sys.argv[5]
timeout_seconds = int(sys.argv[6])
max_attempts = int(sys.argv[7])

deadline = time.monotonic() + timeout_seconds


def remaining():
    value = deadline - time.monotonic()

    if value <= 0:
        raise TimeoutError("MCP deadline exceeded")

    return value


def read_config():
    with config_path.open("rb") as file:
        data = tomllib.load(file)

    entry = data["mcp_servers"]["blender"]

    if entry.get("enabled") is not True:
        raise RuntimeError("Blender MCP is disabled")

    command = pathlib.Path(entry["command"])

    if command.resolve() != uvx_path.resolve():
        raise RuntimeError("Unexpected MCP executable")

    expected_args = [
        "--managed-python",
        "--python",
        "3.12",
        f"mcp-for-blender@{expected_mcp}",
    ]

    if entry.get("args") != expected_args:
        raise RuntimeError("Unexpected MCP arguments")

    if entry.get("env") or entry.get("env_vars"):
        raise RuntimeError("Unexpected MCP environment")

    if entry.get("url") or entry.get("cwd"):
        raise RuntimeError("Unexpected MCP transport settings")

    return entry


def port_available():
    try:
        with socket.create_connection(
            ("127.0.0.1", 9876),
            timeout=0.5,
        ):
            return False

    except ConnectionRefusedError:
        return True

    except OSError as exc:
        if getattr(exc, "winerror", None) == 10061:
            return True

        raise


def verify_listener(pid):
    command = (
        "Get-NetTCPConnection "
        "-LocalPort 9876 -State Listen "
        "-ErrorAction Stop | "
        "Select-Object LocalAddress,OwningProcess | "
        "ConvertTo-Json -Compress"
    )

    shell = (
        pathlib.Path(os.environ["SystemRoot"])
        / "System32"
        / "WindowsPowerShell"
        / "v1.0"
        / "powershell.exe"
    )

    result = subprocess.run(
        [
            str(shell),
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            command,
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=min(10, remaining()),
    )

    listeners = json.loads(result.stdout)

    if isinstance(listeners, dict):
        listeners = [listeners]

    if not listeners:
        raise RuntimeError("MCP listener unavailable")

    for listener in listeners:

        if int(listener["OwningProcess"]) != pid:
            raise RuntimeError("Unexpected listener owner")

        address = ipaddress.ip_address(
            listener["LocalAddress"]
        )

        if not address.is_loopback:
            raise RuntimeError(
                "MCP listener is not restricted to loopback"
            )


async def wait_for_blender(process):
    while remaining() > 0:

        if process.poll() is not None:
            raise RuntimeError("Blender terminated")

        if not port_available():
            verify_listener(process.pid)
            return

        await asyncio.sleep(
            min(0.5, remaining())
        )


def parse_status(result):
    if result.isError:
        raise RuntimeError("MCP returned an error")

    structured = getattr(
        result, "structuredContent", None
    )

    candidates = []

    if isinstance(structured, dict):

        if isinstance(structured.get("result"), str):
            candidates.append(structured["result"])

        elif "blender_version" in structured:
            candidates.append(json.dumps(structured))

    for item in result.content:
        if getattr(item, "type", None) == "text":
            candidates.append(item.text)

    for text in candidates:

        try:
            payload, _ = json.JSONDecoder().raw_decode(
                text.lstrip()
            )

        except (ValueError, TypeError):
            continue

        if not isinstance(payload, dict):
            continue

        if (
            payload.get("source") == "native"
            and payload.get("up_to_date") is True
            and payload.get("blender_version")
        ):
            return payload

    raise RuntimeError(
        "Connected addon status could not be verified"
    )


async def query_status(entry):
    environment = dict(os.environ)
    environment["UV_OFFLINE"] = "1"

    parameters = StdioServerParameters(
        command=entry["command"],
        args=entry["args"],
        env=environment,
    )

    async with asyncio.timeout(remaining()):

        async with stdio_client(parameters) as streams:

            async with ClientSession(
                streams[0], streams[1]
            ) as session:

                await session.initialize()

                tools = await session.list_tools()

                if not any(
                    tool.name == "get_addon_status"
                    for tool in tools.tools
                ):
                    raise RuntimeError(
                        "Read-only status tool unavailable"
                    )

                result = await session.call_tool(
                    "get_addon_status",
                    arguments={},
                )

                payload = parse_status(result)

                match = re.match(
                    r"^(\d+\.\d+\.\d+)",
                    str(payload["blender_version"]),
                )

                if (
                    not match
                    or match.group(1) != expected_blender
                ):
                    raise RuntimeError(
                        "Connected Blender version mismatch"
                    )

                return True


async def query_with_retry(entry):

    for attempt in range(1, max_attempts + 1):

        try:
            return await query_status(entry)

        except (ConnectionError, TimeoutError):

            if attempt >= max_attempts:
                raise

            await asyncio.sleep(
                min(2 ** (attempt - 1), remaining())
            )

    raise RuntimeError("MCP retries exhausted")


async def main():

    entry = read_config()

    observed_version = importlib.metadata.version(
        "mcp-for-blender"
    )

    if observed_version != expected_mcp:
        raise RuntimeError("Resolved MCP version mismatch")

    if not port_available():
        raise RuntimeError(
            "Port 9876 was already occupied before testing"
        )

    # No project file, addon activation or injected Blender code.

    process = subprocess.Popen(
        [
            str(blender_path),
            "--disable-autoexec",
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    try:
        await wait_for_blender(process)

        first = await query_with_retry(entry)

        # A separate MCP session must reconnect successfully.

        second = await query_with_retry(entry)

        verify_listener(process.pid)

        if not first or not second:
            raise RuntimeError("MCP verification failed")

        return {
            "configurationVerified": True,
            "mcpVersion": observed_version,
            "addonActive": True,
            "mcpReadOnlyVerified": first,
            "reconnectionVerified": second,
        }

    finally:

        # Stop only the Blender process started by this test.

        if process.poll() is None:

            process.terminate()

            try:
                process.wait(timeout=5)

            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)


if __name__ == "__main__":

    result = asyncio.run(main())

    print(json.dumps(result))
'@

        [IO.File]::WriteAllText(
            $probePath,
            $pythonProbe,
            [Text.UTF8Encoding]::new($false)
        )
    }


    Context "Installed software versions" {

        It "Verifies the actual Blender version" {

            $state.paths.Blender = Get-CiBlender

            $state.versions.Blender = Get-CiVersion `
                -FilePath $state.paths.Blender `
                -Pattern '(?m)^Blender\s+(\d+\.\d+\.\d+)'

            $state.versions.Blender |
                Should -BeExactly $candidate.Blender

            $state.checks.Blender = $true
        }


        It "Verifies the actual Git version" {

            $state.paths.Git = Get-CiExecutable `
                -Names @("git.exe")

            $gitVersion = Get-CiVersion `
                -FilePath $state.paths.Git `
                -Pattern '(?m)^git version\s+(\d+\.\d+\.\d+(?:\.windows\.\d+)?)'

            # Preserve the Git for Windows build revision.

            $state.versions.Git = $gitVersion `
                -replace '\.windows\.', '.'

            $state.versions.Git |
                Should -BeExactly $candidate.Git

            $state.checks.Git = $true
        }


        It "Verifies the actual UV version" {

            $state.paths.UV = Get-CiExecutable `
                -Names @("uv.exe")

            $state.versions.UV = Get-CiVersion `
                -FilePath $state.paths.UV `
                -Pattern '(?m)^uv\s+(\d+\.\d+\.\d+)\b'

            $state.versions.UV |
                Should -BeExactly $candidate.UV

            $state.checks.UV = $true
        }


        It "Verifies UVX availability and version" {

            $state.paths.UVX = Get-CiExecutable `
                -Names @("uvx.exe")

            $uvxVersion = Get-CiVersion `
                -FilePath $state.paths.UVX `
                -Pattern '(?m)^uvx?\s+(\d+\.\d+\.\d+)\b'

            $uvxVersion |
                Should -BeExactly $candidate.UV

            $state.checks.UVX = $true
        }


        It "Verifies the actual Node.js version" {

            $state.paths.NodeJS = Get-CiExecutable `
                -Names @("node.exe")

            $state.versions.NodeJS = Get-CiVersion `
                -FilePath $state.paths.NodeJS `
                -Pattern '(?m)^v(\d+\.\d+\.\d+)\s*$'

            $state.versions.NodeJS |
                Should -BeExactly $candidate.NodeJS

            $state.checks.NodeJS = $true
        }


        It "Verifies the actual Codex CLI version" {

            $state.paths.Codex = Get-CiExecutable `
                -Names @(
                    "codex.exe",
                    "codex.cmd"
                )

            $state.versions.Codex = Get-CiVersion `
                -FilePath $state.paths.Codex `
                -Pattern '(?m)^codex(?:-cli)?\s+(\d+\.\d+\.\d+)\s*$'

            $state.versions.Codex |
                Should -BeExactly $candidate.Codex

            $state.checks.Codex = $true
        }
    }


    Context "Configuration integrity" {

        It "Finds the isolated Codex configuration" {

            $expectedConfig = Join-Path `
                $env:CODEX_HOME "config.toml"

            [IO.Path]::GetFullPath($ConfigPath) |
                Should -BeExactly (
                    [IO.Path]::GetFullPath($expectedConfig)
                )

            Test-Path `
                -LiteralPath $ConfigPath `
                -PathType Leaf |
                Should -BeTrue

            $configText = Get-Content `
                -LiteralPath $ConfigPath `
                -Raw

            $configText |
                Should -Match (
                    [regex]::Escape(
                        "# CI configuration preservation test"
                    )
                )

            $configText |
                Should -Match (
                    '(?m)^\[mcp_servers\.blender\]\s*$'
                )

            $state.checks.ConfigFile = $true
        }


        It "Confirms Codex recognizes the configured MCP server" {

            $state.paths.Codex |
                Should -Not -BeNullOrEmpty

            $output = Invoke-CiNative `
                -FilePath $state.paths.Codex `
                -Arguments @(
                    "mcp",
                    "list"
                )

            $output |
                Should -Match '(?im)^\s*blender\s+'

            $state.codexConfigurationVerified = $true

            $state.checks.CodexConfig = $true
        }
    }


    Context "Real MCP integration" {

        It "Connects to Blender without manually enabling MCP" {

            $state.checks.ConfigFile |
                Should -BeTrue

            $state.checks.Blender |
                Should -BeTrue

            $state.checks.UVX |
                Should -BeTrue

            $package = "mcp-for-blender@$($candidate.MCP)"

            # Use the cached package environment.
            # Do not silently download missing dependencies.

            $probeOutput = Invoke-CiNative `
                -FilePath $state.paths.UVX `
                -Arguments @(
                    "--offline",
                    "--managed-python",
                    "--python",
                    "3.12",
                    "--from",
                    $package,
                    "python",
                    $probePath,
                    $ConfigPath,
                    $state.paths.Blender,
                    $state.paths.UVX,
                    $candidate.Blender,
                    $candidate.MCP,
                    [string]$McpTimeoutSeconds,
                    [string]$MaxAttempts
                )

            $probe = $probeOutput |
                ConvertFrom-Json

            $state.versions.MCP = $probe.mcpVersion

            $state.versions.MCP |
                Should -BeExactly $candidate.MCP

            foreach ($property in @(
                "configurationVerified",
                "addonActive",
                "mcpReadOnlyVerified",
                "reconnectionVerified"
            )) {
                ($probe.$property -is [bool]) |
                    Should -BeTrue

                $probe.$property |
                    Should -BeTrue
            }

            $state.configurationVerified = `
                $probe.configurationVerified

            $state.addonActive = `
                $probe.addonActive

            $state.mcpReadOnlyVerified = `
                $probe.mcpReadOnlyVerified

            $state.reconnectionVerified = `
                $probe.reconnectionVerified

            $state.checks.MCP = $true
        }
    }


    Context "Zero-Click acceptance" {

        It "Rejects known interactive launcher commands" {

            $launcherPath = Join-Path `
                $RepositoryRoot "Lancer-Windows.bat"

            Test-Path `
                -LiteralPath $launcherPath `
                -PathType Leaf |
                Should -BeTrue

            $launcher = Get-Content `
                -LiteralPath $launcherPath `
                -Raw

            $launcher |
                Should -Not -Match (
                    '(?im)^\s*@?\s*(choice|pause)\b'
                )

            $launcher |
                Should -Not -Match (
                    '(?im)^\s*@?\s*set\s+/p\b'
                )

            $state.launcherVerified = $true

            $state.checks.Launcher = $true
        }


        It "Requires all independent integration checks" {

            $requiredChecks = @(
                "Blender",
                "Git",
                "UV",
                "UVX",
                "NodeJS",
                "Codex",
                "ConfigFile",
                "CodexConfig",
                "MCP",
                "Launcher"
            )

            foreach ($check in $requiredChecks) {

                $state.checks[$check] |
                    Should -BeTrue -Because (
                        "$check must be verified"
                    )
            }

            foreach ($name in $expectedNames) {

                $state.versions[$name] |
                    Should -BeExactly $candidate.$name
            }

            $state.configurationVerified |
                Should -BeTrue

            $state.codexConfigurationVerified |
                Should -BeTrue

            $state.addonActive |
                Should -BeTrue

            $state.mcpReadOnlyVerified |
                Should -BeTrue

            $state.reconnectionVerified |
                Should -BeTrue

            $state.launcherVerified |
                Should -BeTrue

            $state.checks.Acceptance = $true
        }
    }


    AfterAll {

        try {

            # Evidence is produced only from observed results.
            # Never substitute expected candidate versions.

            $complete = (
                $state.checks.Acceptance -eq $true -and
                $state.configurationVerified -eq $true -and
                $state.codexConfigurationVerified -eq $true -and
                $state.addonActive -eq $true -and
                $state.mcpReadOnlyVerified -eq $true -and
                $state.reconnectionVerified -eq $true -and
                $state.launcherVerified -eq $true
            )

            $evidence = [ordered]@{
                schemaVersion = 1

                timestampUtc = `
                    [DateTime]::UtcNow.ToString("o")

                status = if ($complete) {
                    "SUCCESS"
                }
                else {
                    "ERROR"
                }

                versions = $state.versions

                configurationVerified = `
                    $state.configurationVerified

                codexConfigurationVerified = `
                    $state.codexConfigurationVerified

                addonActive = `
                    $state.addonActive

                mcpReadOnlyVerified = `
                    $state.mcpReadOnlyVerified

                reconnectionVerified = `
                    $state.reconnectionVerified

                launcherStaticCheck = `
                    $state.launcherVerified

                zeroClickVerified = $complete

                zeroClickScope = `
                    "Hosted CI installer and MCP startup"

                launcherRuntimeVerified = $false

                desktopAuthenticationVerified = $false

                automaticLogonTriggerVerified = $false

                checks = $state.checks
            }

            $evidence |
                ConvertTo-Json -Depth 10 |
                Set-Content `
                    -LiteralPath $EvidencePath `
                    -Encoding utf8
        }
        finally {

            if ($state.environmentCaptured) {
                $env:Path = $state.originalPath

                [Environment]::SetEnvironmentVariable(
                    "UV_OFFLINE",
                    $state.originalOffline,
                    "Process"
                )
            }
        }
    }
}
