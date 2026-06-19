#Requires -Version 5.1
<#
Windows setup for running Jimmy Discord Bot locally with TinyDolphin GGUF.

Run from PowerShell:
  powershell -ExecutionPolicy Bypass -File .\install_windows_tinydolphin.ps1

Or:
  .\install_windows_tinydolphin.bat
#>

param(
    [switch]$SkipPrereqInstall
)

$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO]  $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "[OK]    $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN]  $Message" -ForegroundColor Yellow }
function Die        { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = ""
    )
    if ($WorkingDirectory) { Push-Location $WorkingDirectory }
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
        }
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }
}

function Refresh-Path {
    $machine = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $user = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machine;$user"
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )
    if ($SkipPrereqInstall) {
        throw "$DisplayName is missing. Re-run without -SkipPrereqInstall or install it manually."
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "$DisplayName is missing and winget was not found. Install it manually, then re-run."
    }
    Write-Warn "$DisplayName is missing. Installing with winget..."
    Invoke-Checked "winget" @(
        "install", "--id", $PackageId, "-e",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
    Refresh-Path
}

function Ensure-Command {
    param(
        [Parameter(Mandatory = $true)][string]$CommandName,
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )
    if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
        Write-Ok "$DisplayName found."
        return
    }
    Install-WingetPackage -PackageId $PackageId -DisplayName $DisplayName
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "$DisplayName was installed, but '$CommandName' is not on PATH yet. Reopen PowerShell and rerun."
    }
    Write-Ok "$DisplayName installed."
}

function Find-Python {
    $candidates = @(
        @{Exe="py"; Args=@("-3.12")},
        @{Exe="py"; Args=@("-3.11")},
        @{Exe="python"; Args=@()},
        @{Exe="python3"; Args=@()}
    )
    foreach ($c in $candidates) {
        if (-not (Get-Command $c.Exe -ErrorAction SilentlyContinue)) { continue }
        try {
            $code = "import sys; raise SystemExit(0 if sys.version_info >= (3,11) else 1)"
            & $c.Exe @($c.Args) -c $code 2>$null
            if ($LASTEXITCODE -eq 0) { return $c }
        }
        catch { }
    }
    return $null
}

function Invoke-BasePython {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $allArgs = @()
    $allArgs += $script:BasePython.Args
    $allArgs += $Arguments
    & $($script:BasePython.Exe) @allArgs
    if ($LASTEXITCODE -ne 0) { throw "Python command failed: $($Arguments -join ' ')" }
}

function Download-File {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        Invoke-Checked "curl.exe" @("-L", "--fail", "--retry", "10", "--retry-delay", "5", "-o", $OutFile, $Url)
    }
    else {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile
    }
}

function Set-FileUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Update-ConfigYaml {
    param([Parameter(Mandatory = $true)][string]$ConfigPath)

    $script = @'
from pathlib import Path
p = Path("config.yaml")
text = p.read_text(encoding="utf-8") if p.exists() else ""
replacements = {
    "src_dir": '  src_dir: "."',
    "executable": '  executable: "./llama_cpp_win/llama-cli.exe"',
    "model": '  model: "./models/tinydolphin/tinydolphin-2.8.1-1.1b-q4_k_m.gguf"',
    "threads": "  threads: 4",
    "context": "  context: 2048",
    "temperature": "  temperature: 0.7",
    "top_p": "  top_p: 0.9",
    "top_k": "  top_k: 40",
    "repeat_penalty": "  repeat_penalty: 1.1",
    "max_tokens": "  max_tokens: 512",
}
if "bitnet:" not in text:
    if text and not text.endswith("\n"):
        text += "\n"
    text += "\nbitnet:\n"
lines = text.splitlines()
out = []
in_bitnet = False
seen = set()
for line in lines:
    if line.startswith("bitnet:"):
        in_bitnet = True
        out.append(line)
        continue
    if in_bitnet and line and not line.startswith(" ") and not line.startswith("#"):
        for key, value in replacements.items():
            if key not in seen:
                out.append(value)
        in_bitnet = False
    if in_bitnet:
        stripped = line.strip()
        key = stripped.split(":", 1)[0] if ":" in stripped else None
        if key in replacements:
            out.append(replacements[key])
            seen.add(key)
            continue
    out.append(line)
if in_bitnet:
    for key, value in replacements.items():
        if key not in seen:
            out.append(value)
p.write_text("\n".join(out) + "\n", encoding="utf-8")
'@
    Push-Location (Split-Path -Parent $ConfigPath)
    try {
        $script | & $VenvPython -
        if ($LASTEXITCODE -ne 0) { throw "Failed to update config.yaml" }
    }
    finally {
        Pop-Location
    }
}

function Install-LlamaCppWindowsBinary {
    param([Parameter(Mandatory = $true)][string]$DestinationDir)

    $cli = Join-Path $DestinationDir "llama-cli.exe"
    if (Test-Path $cli) {
        Write-Ok "llama-cli.exe already present: $cli"
        return
    }

    Write-Info "Downloading latest llama.cpp Windows binary..."
    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null

    $headers = @{ "User-Agent" = "Jimmy-Discord-Windows-Installer" }
    $release = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest"
    $assets = @($release.assets | Where-Object {
        $_.name -match "bin-win.*x64.*\.zip$" -and
        $_.name -notmatch "cuda|vulkan|kompute|sycl|opencl|hip|rocm"
    })

    if (-not $assets -or $assets.Count -eq 0) {
        Write-Warn "Could not find a suitable llama.cpp Windows release asset. Available assets:"
        $release.assets | ForEach-Object { Write-Warn "  $($_.name)" }
        Die "No suitable llama.cpp Windows binary zip found."
    }

    $asset = @($assets | Where-Object { $_.name -match "avx2" } | Select-Object -First 1)
    if (-not $asset) { $asset = @($assets | Where-Object { $_.name -match "avx" } | Select-Object -First 1) }
    if (-not $asset) { $asset = @($assets | Where-Object { $_.name -match "noavx" } | Select-Object -First 1) }
    if (-not $asset) { $asset = @($assets | Select-Object -First 1) }
    $asset = $asset[0]

    Write-Info "Selected asset: $($asset.name)"
    $tmpZip = Join-Path $env:TEMP ("llama-cpp-" + [guid]::NewGuid().ToString() + ".zip")
    $tmpExtract = Join-Path $env:TEMP ("llama-cpp-" + [guid]::NewGuid().ToString())
    try {
        Download-File -Url $asset.browser_download_url -OutFile $tmpZip
        Expand-Archive -Path $tmpZip -DestinationPath $tmpExtract -Force
        $found = Get-ChildItem -Path $tmpExtract -Filter "llama-cli.exe" -Recurse | Select-Object -First 1
        if (-not $found) { Die "Downloaded llama.cpp zip did not contain llama-cli.exe" }
        Copy-Item -Path (Join-Path $found.Directory.FullName "*") -Destination $DestinationDir -Recurse -Force
    }
    finally {
        Remove-Item -Force $tmpZip -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $tmpExtract -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $cli)) { Die "llama-cli.exe was not installed to $cli" }
    Write-Ok "llama-cli.exe installed: $cli"
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = (Get-Location).Path }
$VenvDir = Join-Path $ScriptDir ".venv-win"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$ModelDir = Join-Path $ScriptDir "models\tinydolphin"
$ModelFile = Join-Path $ModelDir "tinydolphin-2.8.1-1.1b-q4_k_m.gguf"
$ModelUrl = "https://huggingface.co/v8karlo/UNCENSORED-TinyDolphin-2.8.1-1.1b-Q4_K_M-GGUF/resolve/main/tinydolphin-2.8.1-1.1b-q4_k_m.gguf?download=true"
$LlamaDir = Join-Path $ScriptDir "llama_cpp_win"
$ConfigPath = Join-Path $ScriptDir "config.yaml"

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host " Jimmy Discord Bot - Windows TinyDolphin setup" -ForegroundColor Cyan
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host ""

Ensure-Command -CommandName "git" -PackageId "Git.Git" -DisplayName "Git"

$script:BasePython = Find-Python
if ($null -eq $script:BasePython) {
    Install-WingetPackage -PackageId "Python.Python.3.12" -DisplayName "Python 3.12"
    Refresh-Path
    $script:BasePython = Find-Python
}
if ($null -eq $script:BasePython) { Die "Python 3.11+ was not found." }

Write-Info "Preparing Python virtual environment..."
if (-not (Test-Path $VenvPython)) {
    Invoke-BasePython -m venv $VenvDir
}
Invoke-Checked $VenvPython @("-m", "pip", "install", "--upgrade", "pip", "setuptools<82", "wheel")
Invoke-Checked $VenvPython @("-m", "pip", "install", "-r", (Join-Path $ScriptDir "requirements.txt"))
Write-Ok "Python environment ready."

Write-Info "Checking TinyDolphin model..."
New-Item -ItemType Directory -Force -Path $ModelDir | Out-Null
if (Test-Path $ModelFile) {
    $size = (Get-Item $ModelFile).Length
    if ($size -lt 100MB) {
        Write-Warn "Existing model file is too small; deleting and redownloading."
        Remove-Item -Force $ModelFile
    }
}
if (-not (Test-Path $ModelFile)) {
    $tmp = $ModelFile + ".part"
    Download-File -Url $ModelUrl -OutFile $tmp
    Move-Item -Force $tmp $ModelFile
}
Write-Ok "TinyDolphin model ready: $ModelFile"

Install-LlamaCppWindowsBinary -DestinationDir $LlamaDir

Write-Info "Updating config.yaml for Windows llama-cli..."
Update-ConfigYaml -ConfigPath $ConfigPath
Write-Ok "config.yaml updated."

if (Test-Path (Join-Path $ScriptDir "memory.db")) {
    $backup = Join-Path $ScriptDir ("memory.db.backup." + (Get-Date -Format "yyyyMMdd-HHmmss"))
    Write-Warn "Backing up old memory.db to $backup"
    Move-Item -Force (Join-Path $ScriptDir "memory.db") $backup
}

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green
Write-Host " Windows TinyDolphin setup complete" -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "To run the bot on Windows:" -ForegroundColor Cyan
Write-Host "  .\.venv-win\Scripts\Activate.ps1" -ForegroundColor White
Write-Host "  `$env:DISCORD_TOKEN='your_token_here'" -ForegroundColor White
Write-Host "  python bot.py" -ForegroundColor White
Write-Host ""
