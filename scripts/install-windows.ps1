# Windows bootstrap v0.1. No execution-policy override or forced elevation.
[CmdletBinding()]
param([switch]$NoLaunch)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:LOCALAPPDATA 'BlenderCodexSetup\setup.log'
New-Item -ItemType Directory -Force (Split-Path $log) | Out-Null
function Note([string]$message) {
    Write-Information -MessageData $message -InformationAction Continue
    Add-Content -LiteralPath $log -Value ("{0:u} {1}" -f (Get-Date), $message)
}
function Initialize-ProcessPath {
    $paths = @($env:Path, [Environment]::GetEnvironmentVariable('Path','Machine'),
        [Environment]::GetEnvironmentVariable('Path','User'),
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links", "$HOME\.local\bin",
        "$env:APPDATA\npm", "$env:ProgramFiles\Git\cmd", "$env:ProgramFiles\nodejs")
    $env:Path = (($paths -join ';') -split ';' | Where-Object { $_ } | Select-Object -Unique) -join ';'
}
function Find-Exe([string]$name) {
    $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $cmd.Source }
}
function Invoke-Checked([string]$exe, [string[]]$arguments) {
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { throw "Echec de $exe (code $LASTEXITCODE)." }
}
function Install-WinGetPackage([string]$id) {
    $winget = Find-Exe 'winget.exe'
    if (-not $winget) { throw "WinGet absent. Demander son installation autorisee." }
    Note "Installation : $id"
    Invoke-Checked $winget @('install','--id',$id,'--exact','--source','winget')
    Initialize-ProcessPath
}
function Initialize-Executable([string]$name,[string]$id) {
    if (-not (Find-Exe $name)) { Install-WinGetPackage $id }
    if (-not (Find-Exe $name)) { throw "$name introuvable. Relancer apres installation ou verifier le PATH." }
    Note "$name : disponible"
}
function Find-Blender {
    $exe = Find-Exe 'blender.exe'
    if ($exe) { return $exe }
    foreach ($root in @("$env:ProgramFiles\Blender Foundation", "$env:LOCALAPPDATA\Programs\Blender Foundation", "$env:LOCALAPPDATA\Programs\Blender")) {
        if (Test-Path -LiteralPath $root) {
            $candidate = Get-ChildItem -LiteralPath $root -Filter blender.exe -File -Recurse -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($candidate) { return $candidate.FullName }
        }
    }
}
function Find-Desktop {
    Get-StartApps -ErrorAction SilentlyContinue | Where-Object {
        $_.AppID -match '^OpenAI\.(Codex|ChatGPT)_'
    } | Select-Object -First 1
}
try {
    Note '=== Installation Windows (v0.1, prototype) ==='
    Initialize-ProcessPath
    $blender = Find-Blender
    if (-not $blender) { Install-WinGetPackage 'BlenderFoundation.Blender'; $blender = Find-Blender }
    if (-not $blender) { throw 'Blender introuvable apres installation.' }
    Note 'Blender : disponible'
    Initialize-Executable 'git.exe' 'Git.Git'
    Initialize-Executable 'uv.exe' 'astral-sh.uv'
    $uv = Find-Exe 'uv.exe'
    $uvx = Find-Exe 'uvx.exe'
    if (-not $uvx) { throw 'UVX introuvable.' }
    # uv python install is idempotent and uses UV-managed Python, not system Python.
    Invoke-Checked $uv @('python','install','3.12')
    Note 'Python 3.12 : disponible'
    $desktop = Find-Desktop
    $codex = Find-Exe 'codex.exe'
    if (-not $codex) { $codex = Find-Exe 'codex.cmd' }
    if (-not $desktop -and -not $codex) {
        # CLI fallback when the desktop application is absent.
        Initialize-Executable 'npm.cmd' 'OpenJS.NodeJS.LTS'
        Invoke-Checked (Find-Exe 'npm.cmd') @('install','-g','@openai/codex')
        Initialize-ProcessPath
        $codex = Find-Exe 'codex.exe'
        if (-not $codex) { $codex = Find-Exe 'codex.cmd' }
        if (-not $codex) { throw 'Codex CLI introuvable apres installation.' }
    }
    Note 'Codex : application detectee ou CLI disponible (connexion a verifier)'
    $mcp = 'mcp-for-blender@2.2.1'
    $uvArgs = @('--managed-python','--python','3.12',$mcp)
    Invoke-Checked $uvx ($uvArgs + @('--help'))
    $versionText = & $blender --version | Select-Object -First 1
    if ($LASTEXITCODE -ne 0 -or $versionText -notmatch 'Blender\s+(\d+\.\d+)') { throw 'Version Blender non detectee.' }
    $version = $Matches[1]
    $addonDir = Join-Path $env:APPDATA "Blender Foundation\Blender\$version\scripts\addons"
    if (-not (Test-Path -LiteralPath (Join-Path $addonDir 'blender_mcp.py'))) {
        $oldDir = $env:BLENDERMCP_ADDONS_DIR
        try {
            $env:BLENDERMCP_ADDONS_DIR = $addonDir
            Invoke-Checked $uvx ($uvArgs + @('install-addon'))
        } finally { $env:BLENDERMCP_ADDONS_DIR = $oldDir }
        if (-not (Test-Path -LiteralPath (Join-Path $addonDir 'blender_mcp.py'))) {
            throw 'Fichier extension MCP introuvable. Verifier le chemin des addons Blender.'
        }
    } else { Note 'Extension MCP : fichier present, conserve.' }
    # Keep the entire existing TOML. Validate before appending with Python.
    $config = Join-Path $HOME '.codex\config.toml'
    if ($env:CODEX_HOME) { $config = Join-Path $env:CODEX_HOME 'config.toml' }
    $helper = @'
import sys, pathlib, tomllib, datetime, shutil, tempfile, os
p = pathlib.Path(sys.argv[1])
uvx = sys.argv[2]
raw = p.read_bytes() if p.exists() else b""
data = tomllib.loads(raw.decode("utf-8-sig"))
servers = data.get("mcp_servers", {})
if "blender" in servers:
    entry = servers["blender"]
    if not isinstance(entry, dict) or entry.get("enabled", True) is False:
        sys.exit("Configuration Blender existante desactivee ou non standard : verifier manuellement.")
    print("Configuration Blender existante conservee. Verifier son chemin UVX et ses arguments.")
    sys.exit(0)
if "'" in uvx or "\n" in uvx or "\r" in uvx:
    sys.exit("Chemin UVX non standard : configuration manuelle necessaire.")
block = ("\n\n[mcp_servers.blender]\n"
         f"command = '{uvx}'\n"
         'args = ["--managed-python", "--python", "3.12", "mcp-for-blender@2.2.1"]\n'
         "startup_timeout_sec = 120\nenabled = true\n")
new = raw + block.encode("utf-8")
tomllib.loads(new.decode("utf-8-sig"))
p.parent.mkdir(parents=True, exist_ok=True)
if p.exists():
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    shutil.copy2(p, p.with_name(p.name + "." + stamp + ".bak"))
fd, name = tempfile.mkstemp(dir=p.parent)
try:
    with os.fdopen(fd, "wb") as file:
        file.write(new)
    os.replace(name, p)
finally:
    if os.path.exists(name):
        os.unlink(name)
print("Configuration MCP ajoutee.")
'@
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("mcp-config-" + [guid]::NewGuid() + ".py")
    try {
        [IO.File]::WriteAllText($tmp, $helper, [Text.UTF8Encoding]::new($false))
        Invoke-Checked $uv @('run','--no-project','--managed-python','--python','3.12','--no-python-downloads',$tmp,$config,$uvx)
    } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    Note 'Configuration preparee. Activation et test MCP restent a verifier.'
    Note 'Si Codex ou Blender etait ouvert, le fermer normalement puis le relancer.'
    if (-not $NoLaunch) {
        if (-not (Get-Process blender -ErrorAction SilentlyContinue)) { Start-Process -FilePath $blender }
        if ($desktop) {
            Start-Process explorer.exe -ArgumentList ("shell:AppsFolder\" + $desktop.AppID)
        } elseif ($codex) {
            Start-Process cmd.exe -ArgumentList ('/k ""' + $codex + '""')
        }
    }
    Note 'Dans Blender : Preferences > Add-ons > MCP for Blender ; N > MCP > connecter si necessaire.'
    Note 'Dans Codex : tester get_addon_status en lecture seule. Ne jamais autoriser tout code automatiquement.'
    Note "Journal local : $log"
    exit 0
} catch {
    Note ("ECHEC : " + $_.Exception.Message)
    Note 'Aucun contournement de droits. Verifier avec le responsable de la machine, puis relancer.'
    exit 1
}
