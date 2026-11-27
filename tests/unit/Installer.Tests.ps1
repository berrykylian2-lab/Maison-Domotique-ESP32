Describe "Windows installer unit tests" {

    BeforeAll {

        $repositoryRoot = [IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot "..\..")
        )

        $installerPath = Join-Path `
            $repositoryRoot "scripts\install-windows.ps1"

        if (-not (Test-Path -LiteralPath $installerPath)) {
            throw "Installer script missing."
        }

        # Parse the installer without executing its main body.

        $tokens = $null
        $parseErrors = $null

        $installerAst = `
            [System.Management.Automation.Language.Parser]::ParseFile(
                $installerPath,
                [ref]$tokens,
                [ref]$parseErrors
            )

        if (@($parseErrors).Count -gt 0) {
            throw "Installer contains PowerShell syntax errors."
        }

        # Load only the required top-level function definitions.

        $requiredFunctions = @(
            "Note",
            "Update-Path",
            "Find-Exe",
            "Invoke-Checked",
            "Install-WinGetPackage",
            "Initialize-Executable",
            "Find-Blender",
            "Find-Desktop"
        )

        $definitions = @(
            $installerAst.EndBlock.Statements |
                Where-Object {
                    $_ -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }
        )

        foreach ($functionName in $requiredFunctions) {

            $matchesFound = @(
                $definitions |
                    Where-Object {
                        $_.Name -ceq $functionName
                    }
            )

            if ($matchesFound.Count -ne 1) {
                throw "Invalid function definition: $functionName"
            }

            . ([scriptblock]::Create(
                $matchesFound[0].Extent.Text
            ))
        }

        $cmdPath = Join-Path `
            $env:SystemRoot "System32\cmd.exe"

        if (-not (Test-Path -LiteralPath $cmdPath)) {
            throw "Windows command interpreter unavailable."
        }
    }


    Context "Installer structure" {

        It "Contains no PowerShell syntax errors" {
            @($parseErrors).Count | Should -Be 0
        }

        It "Contains all required installer functions" {

            foreach ($functionName in $requiredFunctions) {

                Get-Command `
                    -Name $functionName `
                    -CommandType Function `
                    -ErrorAction Stop |
                    Should -Not -BeNullOrEmpty
            }
        }
    }


    Context "Executable discovery" {

        It "Finds an existing executable" {

            $result = Find-Exe $cmdPath

            $result | Should -Be $cmdPath
        }

        It "Returns no executable when it does not exist" {

            $missingName = (
                "missing-ci-" +
                [Guid]::NewGuid().ToString("N") +
                ".exe"
            )

            Find-Exe $missingName |
                Should -BeNullOrEmpty
        }
    }


    Context "Native process exit codes" {

        BeforeEach {

            # Keep native exit-code handling consistent
            # between Windows PowerShell and PowerShell 7.

            if ($PSVersionTable.PSVersion.Major -ge 7) {
                Set-Variable `
                    -Name PSNativeCommandUseErrorActionPreference `
                    -Value $false `
                    -Scope Local
            }
        }

        It "Accepts a successful native command" {

            {
                Invoke-Checked $cmdPath @(
                    "/d",
                    "/c",
                    "exit",
                    "0"
                )
            } | Should -Not -Throw
        }

        It "Rejects a failed native command" {

            {
                Invoke-Checked $cmdPath @(
                    "/d",
                    "/c",
                    "exit",
                    "7"
                )
            } | Should -Throw "*code 7*"
        }
    }


    Context "PATH management" {

        It "Preserves existing PATH entries" {

            $originalPath = $env:Path

            $testPath = Join-Path `
                $TestDrive "existing-path"

            try {

                $env:Path = "$testPath;$originalPath"

                Update-Path

                ($env:Path -split ";") |
                    Should -Contain $testPath
            }
            finally {
                $env:Path = $originalPath
            }
        }

        It "Removes duplicate PATH entries" {

            $originalPath = $env:Path

            $testPath = Join-Path `
                $TestDrive "duplicate-path"

            try {

                $env:Path = "$testPath;$testPath"

                Update-Path

                $entries = @(
                    $env:Path -split ";" |
                        Where-Object {
                            $_ -eq $testPath
                        }
                )

                $entries.Count | Should -Be 1
            }
            finally {
                $env:Path = $originalPath
            }
        }
    }


    Context "Logging" {

        It "Writes the installer message to its log" {

            $log = Join-Path $TestDrive "installer.log"

            $message = (
                "CI unit test " +
                [Guid]::NewGuid().ToString("N")
            )

            Note $message

            Test-Path -LiteralPath $log |
                Should -BeTrue

            Get-Content -LiteralPath $log -Raw |
                Should -Match ([regex]::Escape($message))
        }
    }


    Context "WinGet package installation" {

        BeforeEach {

            Mock Note {}

            Mock Update-Path {}

            Mock Invoke-Checked {}
        }

        It "Requests the expected package from WinGet" {

            Mock Find-Exe {
                "C:\CI\winget.exe"
            }

            Install-WinGetPackage "Git.Git"

            Should -Invoke Invoke-Checked `
                -Exactly `
                -Times 1 `
                -Scope It `
                -ParameterFilter {

                    $exe -eq "C:\CI\winget.exe" -and

                    ($arguments -join "|") -eq (
                        "install|--id|Git.Git|" +
                        "--exact|--source|winget"
                    )
                }
        }

        It "Refreshes PATH after package installation" {

            Mock Find-Exe {
                "C:\CI\winget.exe"
            }

            Install-WinGetPackage "Git.Git"

            Should -Invoke Update-Path `
                -Exactly `
                -Times 1 `
                -Scope It
        }

        It "Stops when WinGet is unavailable" {

            Mock Find-Exe {}

            {
                Install-WinGetPackage "Git.Git"
            } | Should -Throw "*WinGet absent*"

            Should -Invoke Invoke-Checked `
                -Exactly `
                -Times 0 `
                -Scope It
        }

        It "Propagates installation failures" {

            Mock Find-Exe {
                "C:\CI\winget.exe"
            }

            Mock Invoke-Checked {
                throw "Simulated installation failure."
            }

            {
                Install-WinGetPackage "Git.Git"
            } | Should -Throw "*Simulated installation failure*"

            Should -Invoke Update-Path `
                -Exactly `
                -Times 0 `
                -Scope It
        }
    }


    Context "Dependency management" {

        BeforeEach {

            $script:ciUnitInstalled = $false

            Mock Note {}

            Mock Install-WinGetPackage {}
        }

        AfterEach {
            $script:ciUnitInstalled = $false
        }

        It "Does not reinstall an existing dependency" {

            Mock Find-Exe {
                "C:\CI\git.exe"
            }

            Initialize-Executable "git.exe" "Git.Git"

            Should -Invoke Install-WinGetPackage `
                -Exactly `
                -Times 0 `
                -Scope It
        }

        It "Installs a missing dependency only once" {

            Mock Find-Exe {

                if ($script:ciUnitInstalled) {
                    "C:\CI\git.exe"
                }
            }

            Mock Install-WinGetPackage {
                $script:ciUnitInstalled = $true
            }

            Initialize-Executable "git.exe" "Git.Git"

            Should -Invoke Install-WinGetPackage `
                -Exactly `
                -Times 1 `
                -Scope It `
                -ParameterFilter {
                    $id -eq "Git.Git"
                }
        }

        It "Stops when the dependency remains unavailable" {

            Mock Find-Exe {}

            {
                Initialize-Executable "git.exe" "Git.Git"
            } | Should -Throw "*git.exe introuvable*"

            Should -Invoke Install-WinGetPackage `
                -Exactly `
                -Times 1 `
                -Scope It
        }
    }


    Context "Blender discovery" {

        It "Uses Blender from PATH when available" {

            Mock Find-Exe {
                "C:\CI\blender.exe"
            } -ParameterFilter {
                $name -eq "blender.exe"
            }

            Find-Blender |
                Should -Be "C:\CI\blender.exe"
        }

        It "Finds Blender in an alternative directory" {

            Mock Find-Exe {}

            $originalProgramFiles = $env:ProgramFiles
            $originalLocalAppData = $env:LOCALAPPDATA

            try {

                $env:ProgramFiles = Join-Path `
                    $TestDrive "ProgramFiles"

                $env:LOCALAPPDATA = Join-Path `
                    $TestDrive "LocalAppData"

                $blenderDirectory = Join-Path `
                    $env:ProgramFiles `
                    "Blender Foundation\Blender CI"

                New-Item `
                    -ItemType Directory `
                    -Path $blenderDirectory `
                    -Force | Out-Null

                $fakeBlender = Join-Path `
                    $blenderDirectory "blender.exe"

                # Create a discovery fixture.
                # This file is never executed.

                New-Item `
                    -ItemType File `
                    -Path $fakeBlender `
                    -Force | Out-Null

                Find-Blender |
                    Should -Be $fakeBlender
            }
            finally {

                $env:ProgramFiles = $originalProgramFiles

                $env:LOCALAPPDATA = $originalLocalAppData
            }
        }

        It "Returns no Blender path when Blender is absent" {

            Mock Find-Exe {}

            $originalProgramFiles = $env:ProgramFiles
            $originalLocalAppData = $env:LOCALAPPDATA

            try {

                $env:ProgramFiles = Join-Path `
                    $TestDrive "MissingProgramFiles"

                $env:LOCALAPPDATA = Join-Path `
                    $TestDrive "MissingLocalAppData"

                Find-Blender |
                    Should -BeNullOrEmpty
            }
            finally {

                $env:ProgramFiles = $originalProgramFiles

                $env:LOCALAPPDATA = $originalLocalAppData
            }
        }
    }
}
