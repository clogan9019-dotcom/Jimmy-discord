#Requires -Version 5.1
<#
.SYNOPSIS
    Native Windows helper for building the Heretic BitNet GGUF file.

.DESCRIPTION
    This script is meant to be run on a Windows PC with more RAM than a Raspberry Pi.
    It downloads the Heretic BitNet model, builds the BitNet/llama.cpp quantizer,
    converts the model to GGUF, quantizes it to i2_s, and leaves you with:

        models\heretic\ggml-model-i2_s.gguf

    Copy that one GGUF file to the Raspberry Pi at:

        ~/Jimmy-2/Jimmy-discord/models/heretic/ggml-model-i2_s.gguf

.NOTES
    Run from PowerShell:
        powershell -ExecutionPolicy Bypass -File .\install_windows.ps1

    Or run:
        .\install_windows.bat
#>

param(
    [string]$HereticRepo = "askalgore/bitnet-b1.58-2B-4T-heretic",
    [switch]$KeepF16,
    [switch]$SkipPrereqInstall
)

$ErrorActionPreference = "Stop"

# -- Console helpers -----------------------------------------------------------
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

function Set-FileUtf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$Override = ""
    )

    if ($SkipPrereqInstall) {
        throw "$DisplayName is missing. Re-run without -SkipPrereqInstall or install it manually."
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "$DisplayName is missing and winget was not found. Install $DisplayName manually, then re-run this script."
    }

    Write-Warn "$DisplayName is missing. Installing with winget..."
    $args = @(
        "install", "--id", $PackageId, "-e",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements"
    )
    if ($Override) {
        $args += @("--override", $Override)
    }

    Invoke-Checked "winget" $args
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
        throw "$DisplayName was installed, but '$CommandName' is not on PATH yet. Close/reopen PowerShell and run this script again."
    }

    Write-Ok "$DisplayName installed."
}

function Get-VSWherePath {
    $vswhereCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vswhere.exe"
    )

    foreach ($vswhere in $vswhereCandidates) {
        if (Test-Path $vswhere) { return $vswhere }
    }

    return $null
}

function Get-VSInstallPath {
    $vswhere = Get-VSWherePath
    if (-not $vswhere) { return $null }

    $installPath = & $vswhere -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($installPath)) {
        return $installPath.Trim()
    }

    return $null
}

function Test-VSBuildTools {
    return -not [string]::IsNullOrWhiteSpace((Get-VSInstallPath))
}

function Test-VSComponentInstalled {
    param([Parameter(Mandatory = $true)][string[]]$ComponentIds)

    $vswhere = Get-VSWherePath
    if (-not $vswhere) { return $false }

    $args = @("-latest", "-products", "*", "-property", "installationPath", "-requires") + $ComponentIds
    $installPath = & $vswhere @args 2>$null
    return ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($installPath))
}

function Test-ClangCLToolset {
    $installPath = Get-VSInstallPath
    if ([string]::IsNullOrWhiteSpace($installPath)) { return $false }

    # First ask vswhere. This is more reliable than guessing VS's on-disk layout.
    if (Test-VSComponentInstalled @(
        "Microsoft.VisualStudio.Component.VC.Llvm.Clang",
        "Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset"
    )) {
        return $true
    }

    # Fallback filesystem check. VS layouts vary between Community/BuildTools and versions.
    $hasClangExe = $false
    $clangRoots = @(
        (Join-Path $installPath "VC\Tools"),
        (Join-Path $installPath "VC")
    )
    foreach ($root in $clangRoots) {
        if (Test-Path $root) {
            $found = Get-ChildItem -Path $root -Filter "clang-cl.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $hasClangExe = $true; break }
        }
    }

    $hasToolset = $false
    $msbuildRoot = Join-Path $installPath "MSBuild\Microsoft\VC"
    if (Test-Path $msbuildRoot) {
        $found = Get-ChildItem -Path $msbuildRoot -Filter "Toolset.props" -Recurse -ErrorAction SilentlyContinue |
            Where-Object {
                $_.FullName.Contains("\PlatformToolsets\ClangCL\") -or
                $_.FullName.Contains("\PlatformToolsets\LLVM\")
            } |
            Select-Object -First 1
        if ($found) { $hasToolset = $true }
    }

    return ($hasClangExe -and $hasToolset)
}

function Invoke-VSInstallerModify {
    param([Parameter(Mandatory = $true)][string]$InstallPath)

    if ($SkipPrereqInstall) {
        throw "Visual Studio ClangCL components are missing. Re-run without -SkipPrereqInstall or install them manually."
    }

    $installerCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vs_installer.exe",
        "$env:ProgramFiles\Microsoft Visual Studio\Installer\vs_installer.exe"
    )

    $installer = $null
    foreach ($candidate in $installerCandidates) {
        if (Test-Path $candidate) { $installer = $candidate; break }
    }

    if (-not $installer) {
        throw "Visual Studio Installer was not found. Open Visual Studio Installer manually and add 'C++ Clang Compiler for Windows' plus 'MSBuild support for LLVM (clang-cl) toolset'."
    }

    Write-Warn "Visual Studio is missing the ClangCL toolset required by BitNet. Installing the missing VS components..."
    Write-Warn "If Windows asks for admin permission, approve it. You may need to re-run this script afterward."

    $args = @(
        "modify",
        "--installPath", $InstallPath,
        "--quiet", "--norestart",
        "--add", "Microsoft.VisualStudio.Component.VC.Llvm.Clang",
        "--add", "Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset"
    )

    Invoke-Checked $installer $args
}

function Ensure-VSBuildTools {
    if (-not (Test-VSBuildTools)) {
        $override = "--quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --add Microsoft.VisualStudio.Component.VC.Llvm.Clang --add Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset --add Microsoft.VisualStudio.Component.VC.CMake.Project"
        Install-WingetPackage -PackageId "Microsoft.VisualStudio.2022.BuildTools" -DisplayName "Visual Studio 2022 C++ Build Tools" -Override $override

        if (-not (Test-VSBuildTools)) {
            throw "Visual Studio Build Tools did not appear to install correctly. Reboot or open a new PowerShell window, then re-run this script."
        }
    }

    Write-Ok "Visual Studio C++ Build Tools found."

    if (-not (Test-ClangCLToolset)) {
        Write-Warn "Visual Studio's ClangCL/MSBuild toolset was not detected. That's OK; this script will build with Ninja + clang-cl directly instead."
        return
    }

    Write-Ok "Visual Studio ClangCL toolset found."
}

function Test-PythonCandidate {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$PrefixArgs = @(),
        [int]$MinMinor = 11,
        [int]$MaxMinor = 13
    )

    try {
        $code = "import sys; print(str(sys.executable) + '|' + str(sys.version_info.major) + '.' + str(sys.version_info.minor))"
        $out = & $Exe @PrefixArgs -c $code 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($out)) { return $null }
        $parts = $out.Trim().Split('|')
        $ver = [version]$parts[-1]
        if ($ver.Major -eq 3 -and $ver.Minor -ge $MinMinor -and $ver.Minor -le $MaxMinor) {
            return [pscustomobject]@{ Exe = $Exe; PrefixArgs = $PrefixArgs; Version = $ver; Path = $parts[0] }
        }
    }
    catch {
        return $null
    }

    return $null
}

function Find-Python {
    # Prefer 3.12/3.11 because PyTorch wheels are usually safest there.
    $candidates = @(
        [pscustomobject]@{ Exe = "py";      Args = @("-3.12") },
        [pscustomobject]@{ Exe = "py";      Args = @("-3.11") },
        [pscustomobject]@{ Exe = "python";  Args = @() },
        [pscustomobject]@{ Exe = "python3"; Args = @() },
        [pscustomobject]@{ Exe = "py";      Args = @("-3.13") }
    )

    foreach ($candidate in $candidates) {
        if (-not (Get-Command $candidate.Exe -ErrorAction SilentlyContinue)) { continue }
        $result = Test-PythonCandidate -Exe $candidate.Exe -PrefixArgs $candidate.Args
        if ($null -ne $result) { return $result }
    }

    return $null
}

function Invoke-BasePython {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $allArgs = @()
    $allArgs += $script:BasePython.PrefixArgs
    $allArgs += $Arguments
    & $($script:BasePython.Exe) @allArgs
    if ($LASTEXITCODE -ne 0) { throw "Python command failed: $($Arguments -join ' ')" }
}

function Get-CommandSource {
    param([Parameter(Mandatory = $true)][string]$CommandName)
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Find-VcVars64 {
    $installPath = Get-VSInstallPath
    if ([string]::IsNullOrWhiteSpace($installPath)) { return $null }

    $candidates = @(
        (Join-Path $installPath "VC\Auxiliary\Build\vcvars64.bat"),
        (Join-Path $installPath "Common7\Tools\VsDevCmd.bat")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

function Find-ClangCl {
    $candidates = @()

    $fromPath = Get-CommandSource "clang-cl"
    if ($fromPath) { $candidates += $fromPath }

    $vsPath = Get-VSInstallPath
    if (-not [string]::IsNullOrWhiteSpace($vsPath)) {
        $candidates += @(
            (Join-Path $vsPath "VC\Tools\Llvm\x64\bin\clang-cl.exe"),
            (Join-Path $vsPath "VC\Tools\Llvm\bin\clang-cl.exe")
        )

        $llvmRoot = Join-Path $vsPath "VC\Tools"
        if (Test-Path $llvmRoot) {
            $found = Get-ChildItem -Path $llvmRoot -Filter "clang-cl.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) { $candidates += $found.FullName }
        }
    }

    $candidates += @(
        "C:\Program Files\LLVM\bin\clang-cl.exe",
        "C:\Program Files (x86)\LLVM\bin\clang-cl.exe"
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) { return $candidate }
    }

    return $null
}

function Ensure-Ninja {
    if (Get-Command "ninja" -ErrorAction SilentlyContinue) {
        Write-Ok "Ninja found."
        return (Get-CommandSource "ninja")
    }

    $null = Install-WingetPackage -PackageId "Ninja-build.Ninja" -DisplayName "Ninja"
    Refresh-Path

    if (-not (Get-Command "ninja" -ErrorAction SilentlyContinue)) {
        throw "Ninja was installed, but it is not on PATH yet. Close/reopen PowerShell and run this script again."
    }

    Write-Ok "Ninja installed."
    return (Get-CommandSource "ninja")
}

function Ensure-ClangCl {
    $clangCl = Find-ClangCl
    if ($clangCl) {
        Write-Ok "clang-cl found: $clangCl"
        return $clangCl
    }

    Write-Warn "clang-cl.exe was not found. Installing standalone LLVM with winget..."
    $null = Install-WingetPackage -PackageId "LLVM.LLVM" -DisplayName "LLVM/Clang"
    Refresh-Path

    $clangCl = Find-ClangCl
    if (-not $clangCl) {
        throw "clang-cl.exe is still missing. Install LLVM manually from https://github.com/llvm/llvm-project/releases or install the Visual Studio Clang tools, then reopen PowerShell and rerun."
    }

    Write-Ok "clang-cl installed: $clangCl"
    return $clangCl
}

function Quote-CmdArg {
    param([Parameter(Mandatory = $true)][string]$Arg)
    if ($Arg -match '[\s&()\[\]{}^=;!''+,`~]') {
        return '"' + ($Arg -replace '"', '\"') + '"'
    }
    return $Arg
}

function Invoke-CheckedVsDev {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = ""
    )

    $vcvars = Find-VcVars64
    if (-not $vcvars) {
        throw "Could not find vcvars64.bat. Install Visual Studio C++ Build Tools, then rerun."
    }

    $cmdParts = @()
    $cmdParts += "call $(Quote-CmdArg $vcvars) >nul"
    if ($WorkingDirectory) {
        $cmdParts += "cd /d $(Quote-CmdArg $WorkingDirectory)"
    }

    $resolvedFile = $FilePath
    if (-not (Test-Path $resolvedFile)) {
        $src = Get-CommandSource $FilePath
        if ($src) { $resolvedFile = $src }
    }

    $commandLine = Quote-CmdArg $resolvedFile
    foreach ($arg in $Arguments) {
        $commandLine += " " + (Quote-CmdArg $arg)
    }
    $cmdParts += $commandLine

    $cmdLine = $cmdParts -join " && "
    & cmd.exe /d /s /c $cmdLine
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Get-QuantizerPath {
    $candidates = @(
        (Join-Path $BitnetDir "build\bin\Release\llama-quantize.exe"),
        (Join-Path $BitnetDir "build\bin\llama-quantize.exe"),
        (Join-Path $BitnetDir "build\bin\Debug\llama-quantize.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

function Build-BitNetQuantizer {
    $existing = Get-QuantizerPath
    if ($existing) {
        Write-Info "BitNet quantizer already built: $existing"
        return $existing
    }

    Write-Info "Generating BitNet x86_64 kernel files..."
    Invoke-Checked $VenvPython @(
        "utils\codegen_tl2.py",
        "--model", "bitnet_b1_58-3B",
        "--BM", "160,320,320",
        "--BK", "96,96,96",
        "--bm", "32,32,32"
    ) $BitnetDir

    $buildDir = Join-Path $BitnetDir "build"
    if (Test-Path $buildDir) {
        Write-Warn "Removing old BitNet build directory to avoid stale generator/config issues."
        Remove-Item -Recurse -Force $buildDir
    }

    Write-Info "Checking Ninja and clang-cl for a Windows Ninja build..."
    $ninjaPath = Ensure-Ninja
    $clangClPath = Ensure-ClangCl
    Write-Info "Using Ninja: $ninjaPath"
    Write-Info "Using clang-cl: $clangClPath"

    Write-Info "Configuring BitNet build with CMake / Ninja / clang-cl..."
    try {
        if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir }
        Invoke-CheckedVsDev "cmake" @(
            "-B", "build",
            "-G", "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DBITNET_X86_TL2=OFF",
            "-DCMAKE_C_COMPILER=$clangClPath",
            "-DCMAKE_CXX_COMPILER=$clangClPath",
            "-DCMAKE_MAKE_PROGRAM=$ninjaPath"
        ) $BitnetDir
    }
    catch {
        Write-Warn $_.Exception.Message
        Die "CMake Ninja/clang-cl configuration failed. Make sure Visual Studio C++ Build Tools, Windows SDK, Ninja, and LLVM/clang-cl are installed. If your repo is under a path with spaces, move it to C:\Jimmy-discord and rerun."
    }

    Write-Info "Compiling BitNet quantizer with Ninja. This can take a while..."
    Invoke-CheckedVsDev "cmake" @("--build", "build", "--config", "Release") $BitnetDir

    $built = Get-QuantizerPath
    if (-not $built) {
        Die "Build finished, but llama-quantize.exe was not found under bitnet_cpp_src\build\bin."
    }

    Write-Ok "BitNet quantizer built: $built"
    return $built
}

function Patch-BitNetConverter {
    Write-Info "Patching BitNet converter for LLaMA-3 BPE tokenizer..."
    $convertText = Get-Content -Raw -Path $ConvertScript
    $convertText = [regex]::Replace($convertText, 'self\._set_vocab_(sentencepiece|llama_hf)\(\)', 'self._set_vocab_gpt2()')
    Set-FileUtf8NoBom -Path $ConvertScript -Text $convertText

    Write-Info "Patching BitNet converter to consume offline .weight_scale tensors..."
    $patchCode = @'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

# Newer tokenizer/transformers combinations produce this checksum for the
# heretic model, but it is still the LLaMA-3 BPE pre-tokenizer.
if "f15ce481ca8fccf8c06fd3d936c1c7f79b64c61a92f6cf846fcf725ff98f4461" not in text:
    text = text.replace(
        "        res = None\n\n        # NOTE:",
        "        res = None\n\n"
        "        if chkhsh == \"f15ce481ca8fccf8c06fd3d936c1c7f79b64c61a92f6cf846fcf725ff98f4461\":\n"
        "            # ref: askalgore/bitnet-b1.58-2B-4T-heretic (LLaMA-3 BPE)\n"
        "            res = \"llama-bpe\"\n\n"
        "        # NOTE:",
        1,
    )

# Microsoft BitNet's converter currently maps regular weight/bias tensors, but
# offline AutoBitLinear checkpoints also contain sibling `.weight_scale` tensors.
# The heretic checkpoint stores unpacked ternary BF16 weights plus those scales;
# upstream BitNet checkpoints may store packed U8 weights plus those scales. GGUF
# has no separate mapping for `.weight_scale`, so consume the scales here and
# skip the scale tensors during conversion. The patch is idempotent.
if "self._bitnet_skip_weight_quant" not in text:
    old_modify = '''    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        # quant weight to i2 (in fp16)
        if name.endswith(("q_proj.weight", "k_proj.weight", "v_proj.weight", 
                          "down_proj.weight", "up_proj.weight", "gate_proj.weight",
                          "o_proj.weight")):
            data_torch = self.weight_quant(data_torch)

        return [(self.map_tensor_name(name), data_torch)]
'''
    new_modify = '''    def modify_tensors(self, data_torch: Tensor, name: str, bid: int | None) -> Iterable[tuple[str, Tensor]]:
        # Some BitNet/AutoBitLinear checkpoints store pre-quantized ternary
        # weights plus a sibling .weight_scale tensor. write_tensors() consumes
        # those scales before tensors get here, so do not re-quantize them.
        if name in getattr(self, "_bitnet_skip_weight_quant", set()):
            return [(self.map_tensor_name(name), data_torch)]

        # quant weight to i2 (in fp16)
        if name.endswith(("q_proj.weight", "k_proj.weight", "v_proj.weight", 
                          "down_proj.weight", "up_proj.weight", "gate_proj.weight",
                          "o_proj.weight")):
            data_torch = self.weight_quant(data_torch)

        return [(self.map_tensor_name(name), data_torch)]
'''
    if old_modify not in text:
        raise SystemExit("Could not patch BitNet converter modify_tensors block; upstream changed.")
    text = text.replace(old_modify, new_modify, 1)

    old_write = '''    def write_tensors(self):
        max_name_len = max(len(s) for _, s in self.tensor_map.mapping.values()) + len(".weight,")

        for name, data_torch in self.get_tensors():
            # we don't need these
            if name.endswith((".attention.masked_bias", ".attention.bias", ".rotary_emb.inv_freq")):
                continue

            old_dtype = data_torch.dtype

            # convert any unsupported data types to float32
'''
    new_write = '''    def write_tensors(self):
        max_name_len = max(len(s) for _, s in self.tensor_map.mapping.values()) + len(".weight,")

        scale_map = {}
        for name, data_torch in self.get_tensors():
            if name.endswith("weight_scale"):
                scale_map[name.replace(".weight_scale", "")] = data_torch.to(torch.float32)
        self._bitnet_skip_weight_quant = set()

        for name, data_torch in self.get_tensors():
            if name.endswith("weight_scale"):
                continue

            # Offline BitNet/AutoBitLinear checkpoints store a ternary weight
            # tensor plus a sibling scalar .weight_scale. GGUF expects the
            # de-scaled float weights and has no tensor mapping for weight_scale.
            if name.endswith(".weight"):
                scale = scale_map.get(name[:-len(".weight")])
                if scale is not None:
                    if data_torch.dtype == torch.uint8:
                        origin_shape = data_torch.shape
                        shift = torch.tensor([0, 2, 4, 6], dtype=torch.uint8).reshape((4, *(1 for _ in range(len(origin_shape)))))
                        data_torch = data_torch.unsqueeze(0).expand((4, *origin_shape)) >> shift
                        data_torch = data_torch & 3
                        data_torch = (data_torch.float() - 1).reshape((origin_shape[0] * 4, *origin_shape[1:]))
                    else:
                        data_torch = data_torch.to(torch.float32)
                    data_torch = data_torch / scale.float()
                    self._bitnet_skip_weight_quant.add(name)

            # we don't need these
            if name.endswith((".attention.masked_bias", ".attention.bias", ".rotary_emb.inv_freq")):
                continue

            old_dtype = data_torch.dtype

            # convert any unsupported data types to float32
'''
    if old_write not in text:
        raise SystemExit("Could not patch BitNet converter write_tensors block; upstream changed.")
    text = text.replace(old_write, new_write, 1)
    path.write_text(text, encoding="utf-8")
'@

    $patchCode | & $VenvPython - $ConvertScript
    if ($LASTEXITCODE -ne 0) { Die "Converter weight_scale patch failed." }

    Write-Ok "BitNet converter patched."
}

# -- Paths/config --------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($ScriptDir)) { $ScriptDir = (Get-Location).Path }

$VenvDir = Join-Path $ScriptDir ".venv-win"
$VenvPython = Join-Path $VenvDir "Scripts\python.exe"
$VenvPip = Join-Path $VenvDir "Scripts\pip.exe"

$BitnetRepo = "https://github.com/microsoft/BitNet.git"
$BitnetDir = Join-Path $ScriptDir "bitnet_cpp_src"
$ConvertScript = Join-Path $BitnetDir "utils\convert-hf-to-gguf-bitnet.py"

$HereticDir = Join-Path $ScriptDir "models\heretic"
$HereticF16 = Join-Path $HereticDir "model-f16.gguf"
$HereticGGUF = Join-Path $HereticDir "ggml-model-i2_s.gguf"

# -- Banner -------------------------------------------------------------------
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host " Discord BitNet Bot - Windows GGUF Builder" -ForegroundColor Cyan
Write-Host " Output: models\heretic\ggml-model-i2_s.gguf" -ForegroundColor Cyan
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Warn "This is a PC-side builder only. Do not copy .venv-win or bitnet_cpp_src\build to the Raspberry Pi."
Write-Warn "Expect high RAM and disk usage. Recommended: 16+ GB RAM and 15+ GB free disk."
Write-Host ""

if ($ScriptDir -match '\s') {
    Write-Warn "Your repo path contains spaces: $ScriptDir"
    Write-Warn "The script tries to quote paths correctly, but a no-space path like C:\Jimmy-discord is safer."
}

# -- Step 1: Windows prerequisites ---------------------------------------------
Write-Info "Step 1/6: Checking Windows prerequisites..."
Ensure-Command -CommandName "git" -PackageId "Git.Git" -DisplayName "Git"
Ensure-Command -CommandName "cmake" -PackageId "Kitware.CMake" -DisplayName "CMake"
Ensure-VSBuildTools

$script:BasePython = Find-Python
if ($null -eq $script:BasePython) {
    Install-WingetPackage -PackageId "Python.Python.3.12" -DisplayName "Python 3.12"
    Refresh-Path
    $script:BasePython = Find-Python
}
if ($null -eq $script:BasePython) {
    Die "Python 3.11+ was not found. Install Python 3.12, reopen PowerShell, and run this script again."
}
Write-Ok "Using Python $($script:BasePython.Version): $($script:BasePython.Path)"

# -- Step 2: Python virtual environment ----------------------------------------
Write-Info "Step 2/6: Creating/updating Python virtual environment..."
if ((Test-Path $VenvDir) -and -not (Test-Path $VenvPython)) {
    Write-Warn "Existing .venv-win is broken; recreating it."
    Remove-Item -Recurse -Force $VenvDir
}
if (-not (Test-Path $VenvPython)) {
    Invoke-BasePython -m venv $VenvDir
}

Invoke-Checked $VenvPython @("-m", "pip", "install", "--upgrade", "pip", "setuptools<82", "wheel")
Invoke-Checked $VenvPython @("-m", "pip", "install", "numpy", "sentencepiece", "transformers", "gguf", "protobuf", "huggingface_hub", "safetensors", "tokenizers")
Invoke-Checked $VenvPython @("-m", "pip", "install", "torch", "--index-url", "https://download.pytorch.org/whl/cpu")
Write-Ok "Python dependencies installed."

# -- Step 3: Clone/update BitNet -----------------------------------------------
Write-Info "Step 3/6: Cloning/updating Microsoft BitNet..."
if (-not (Test-Path $BitnetDir)) {
    Invoke-Checked "git" @("clone", "--recurse-submodules", $BitnetRepo, $BitnetDir)
}
elseif (Test-Path (Join-Path $BitnetDir ".git")) {
    Invoke-Checked "git" @("-C", $BitnetDir, "pull", "--ff-only")
    Invoke-Checked "git" @("-C", $BitnetDir, "submodule", "update", "--init", "--recursive")
}
else {
    Die "$BitnetDir exists but is not a Git checkout. Rename/delete it and run again."
}

Invoke-Checked $VenvPython @("-m", "pip", "install", (Join-Path $BitnetDir "3rdparty\llama.cpp\gguf-py"))
Write-Ok "BitNet source ready."

# -- Step 4: Build quantizer ---------------------------------------------------
Write-Info "Step 4/6: Building BitNet quantizer..."
$Quantizer = $null
try {
    $Quantizer = Build-BitNetQuantizer
}
catch {
    Write-Warn "Native Windows quantizer build failed: $($_.Exception.Message)"
    Write-Warn "Continuing in conversion-only mode. This will create model-f16.gguf on Windows."
    Write-Warn "Transfer model-f16.gguf to the Pi, and the Pi installer will do the final i2_s quantization with its already-built ARM64 quantizer."
}

# -- Step 5: Download Heretic model --------------------------------------------
Write-Info "Step 5/6: Downloading/checking Heretic model files..."
New-Item -ItemType Directory -Force -Path $HereticDir | Out-Null
if (-not (Test-Path (Join-Path $HereticDir "config.json"))) {
    $downloadCode = @'
import sys
from huggingface_hub import snapshot_download
repo_id, local_dir = sys.argv[1], sys.argv[2]
print(f"Downloading {repo_id} to {local_dir} ...", flush=True)
snapshot_download(repo_id=repo_id, local_dir=local_dir)
print("Download complete.", flush=True)
'@
    $downloadCode | & $VenvPython - $HereticRepo $HereticDir
    if ($LASTEXITCODE -ne 0) { Die "Heretic model download failed." }
}
else {
    Write-Info "Heretic model files already present; skipping download."
}
Write-Ok "Heretic model files ready."

# -- Step 6: Convert + optional quantize ---------------------------------------
if ($Quantizer) {
    Write-Info "Step 6/6: Converting Heretic model to GGUF and quantizing to i2_s..."
}
else {
    Write-Info "Step 6/6: Converting Heretic model to F16 GGUF for transfer to the Pi..."
}

$OutputFile = $null
$RemoteFileName = $null
$OutputKind = $null

if (Test-Path $HereticGGUF) {
    Write-Ok "Final i2_s GGUF already exists: $HereticGGUF"
    $OutputFile = $HereticGGUF
    $RemoteFileName = "ggml-model-i2_s.gguf"
    $OutputKind = "final i2_s GGUF"
}
else {
    if (Test-Path $HereticF16) {
        $f16SizeBytes = (Get-Item $HereticF16).Length
        if ($f16SizeBytes -lt 1GB) {
            Write-Warn "Existing F16 GGUF is smaller than 1 GB, so it is probably a partial failed conversion. Removing it."
            Remove-Item -Force $HereticF16
        }
    }

    if (Test-Path $HereticF16) {
        Write-Info "F16 GGUF already exists: $HereticF16"
        Write-Info "Using existing F16 file. If it came from a failed/partial conversion, delete it and rerun."
    }
    else {
        Patch-BitNetConverter

        $configPath = Join-Path $HereticDir "config.json"
        Write-Info "Patching Heretic config architecture name..."
        $configText = Get-Content -Raw -Path $configPath
        $configText = $configText -replace 'BitNetForCausalLM', 'BitnetForCausalLM'
        Set-FileUtf8NoBom -Path $configPath -Text $configText

        Write-Info "Converting to F16 GGUF. This is the high-RAM step..."
        Invoke-Checked $VenvPython @($ConvertScript, $HereticDir, "--outfile", $HereticF16, "--outtype", "f16")

        if (-not (Test-Path $HereticF16)) {
            Die "F16 GGUF conversion did not produce $HereticF16"
        }

        Write-Ok "F16 GGUF created: $HereticF16"
    }

    if ($Quantizer) {
        Write-Info "Quantizing to i2_s..."
        Invoke-Checked $Quantizer @($HereticF16, $HereticGGUF, "I2_S")

        if (-not (Test-Path $HereticGGUF)) {
            Die "Quantization did not produce $HereticGGUF"
        }

        if (-not $KeepF16) {
            Write-Info "Removing intermediate F16 GGUF to save disk space..."
            Remove-Item -Force $HereticF16
        }

        Write-Ok "Final i2_s GGUF created: $HereticGGUF"
        $OutputFile = $HereticGGUF
        $RemoteFileName = "ggml-model-i2_s.gguf"
        $OutputKind = "final i2_s GGUF"
    }
    else {
        Write-Ok "Conversion-only output ready: $HereticF16"
        Write-Warn "This is an F16 intermediate. It is larger than the final i2_s file, but it avoids the RAM-heavy HF conversion on the Pi."
        Write-Warn "After transfer, the Pi installer will quantize this F16 GGUF to ggml-model-i2_s.gguf."
        $OutputFile = $HereticF16
        $RemoteFileName = "model-f16.gguf"
        $OutputKind = "F16 intermediate GGUF"
    }
}

$size = (Get-Item $OutputFile).Length / 1GB
$RemotePath = "~/Jimmy-2/Jimmy-discord/models/heretic/$RemoteFileName"
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green
Write-Host " Windows GGUF build complete" -ForegroundColor Green
Write-Host " Type: $OutputKind" -ForegroundColor Green
Write-Host " File: $OutputFile" -ForegroundColor Green
Write-Host (" Size: {0:N2} GB" -f $size) -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Copy it to your Raspberry Pi with something like:" -ForegroundColor Cyan
Write-Host ""
Write-Host "scp `"$OutputFile`" clogan@YOUR_PI_IP:$RemotePath" -ForegroundColor White
Write-Host ""
Write-Host "Then on the Pi:" -ForegroundColor Cyan
Write-Host ""
Write-Host "cd ~/Jimmy-2/Jimmy-discord" -ForegroundColor White
Write-Host "git pull --ff-only && bash install.sh" -ForegroundColor White
if ($RemoteFileName -eq "model-f16.gguf") {
    Write-Host ""
    Write-Warn "Because you are transferring model-f16.gguf, make sure the Pi has the latest install.sh. The latest installer will keep model-f16.gguf and quantize it instead of deleting it."
}
Write-Host ""
