# Installs Emerald on Windows. In PowerShell:
#
#     irm https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.ps1 | iex
#
# It downloads the latest release from GitHub, checks it against the release's
# SHA256SUMS, puts emerald.exe in %LOCALAPPDATA%\Programs\Emerald, and adds that
# folder to your user PATH. It needs no administrator rights. Running it again
# updates Emerald.
#
# To pass an option, run the script as a script block:
#
#     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.ps1))) -Version v0.5.0
#     & ([scriptblock]::Create((irm https://raw.githubusercontent.com/amortimer20/emerald-lang/main/install.ps1))) -Uninstall
#
# EMERALD_HOME changes the install folder.

param(
    [string]$Version = 'latest',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
# Invoke-WebRequest's progress bar makes downloads many times slower in Windows PowerShell.
$ProgressPreference = 'SilentlyContinue'

$Repo = 'amortimer20/emerald-lang'
$Asset = 'emerald-windows-x86_64.zip'
$InstallDir = if ($env:EMERALD_HOME) { $env:EMERALD_HOME } else { Join-Path $env:LOCALAPPDATA 'Programs\Emerald' }

# A problem is thrown to the one handler at the end of this script, which prints
# it once. `exit` would close the window of a student who ran this through `iex`.
function Fail([string]$Message) {
    throw $Message
}

# The user PATH is read and written through the registry so entries such as
# %USERPROFILE%\bin stay unexpanded; [Environment]::GetEnvironmentVariable would
# expand them and write them back as fixed paths.
function Get-UserPath {
    $key = Get-Item 'HKCU:\Environment'
    return [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
}

function Set-UserPath([string]$Value) {
    Set-ItemProperty 'HKCU:\Environment' -Name 'Path' -Value $Value -Type ExpandString
    # Setting any user variable through .NET tells running programs, such as
    # Explorer, that the environment changed, so new terminals see the new PATH.
    [Environment]::SetEnvironmentVariable('EMERALD_INSTALLER', '1', 'User')
    [Environment]::SetEnvironmentVariable('EMERALD_INSTALLER', $null, 'User')
}

function Split-PathList([string]$Value) {
    return @($Value -split ';' | Where-Object { $_ -ne '' })
}

function Test-SameFolder([string]$Entry, [string]$Folder) {
    $expanded = [Environment]::ExpandEnvironmentVariables($Entry).TrimEnd('\')
    return $expanded -ieq $Folder.TrimEnd('\')
}

function Install-Emerald {
    if ($Uninstall) {
        if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
        $entries = Split-PathList (Get-UserPath)
        $kept = @($entries | Where-Object { -not (Test-SameFolder $_ $InstallDir) })
        if ($kept.Count -ne $entries.Count) {
            Set-UserPath ($kept -join ';')
            Write-Host "Removed $InstallDir from your PATH"
        }
        Write-Host 'Emerald is uninstalled. Open a new terminal to finish.'
        return
    }

    # Windows on ARM runs the x86-64 build through its built-in emulation.
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64' -and $arch -ne 'ARM64') {
        Fail "Emerald's Windows release is for 64-bit Windows, and this is $arch"
    }

    # Windows PowerShell 5.1 may not offer TLS 1.2 by default, which GitHub requires.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $base = if ($Version -eq 'latest') {
        "https://github.com/$Repo/releases/latest/download"
    } else {
        "https://github.com/$Repo/releases/download/$Version"
    }

    $temp = Join-Path ([IO.Path]::GetTempPath()) ("emerald-install-" + [Guid]::NewGuid())
    New-Item -ItemType Directory -Path $temp | Out-Null
    try {
        Write-Host "Downloading $Asset ($Version)..."
        $zip = Join-Path $temp $Asset
        $sums = Join-Path $temp 'SHA256SUMS'
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$Asset" -OutFile $zip
        } catch {
            Fail "could not download $base/$Asset; check the version and your connection"
        }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/SHA256SUMS" -OutFile $sums
        } catch {
            Fail "could not download the release's SHA256SUMS"
        }

        # A line is "<hash>  <name>" or, for a binary-mode checksum, "<hash> *<name>".
        $expected = $null
        foreach ($line in Get-Content $sums) {
            $parts = $line.Trim() -split '\s+', 2
            if ($parts.Count -eq 2 -and $parts[1].TrimStart('*') -eq $Asset) { $expected = $parts[0] }
        }
        if (-not $expected) { Fail "the release's SHA256SUMS has no line for $Asset" }
        $actual = (Get-FileHash -Algorithm SHA256 $zip).Hash
        if ($actual -ne $expected) { Fail 'the download does not match its checksum; try again' }

        $unpacked = Join-Path $temp 'unpacked'
        Expand-Archive -Path $zip -DestinationPath $unpacked
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        try {
            Copy-Item (Join-Path $unpacked 'emerald.exe') (Join-Path $InstallDir 'emerald.exe') -Force
        } catch {
            Fail 'could not replace emerald.exe; close any program that is running Emerald (such as VS Code) and try again'
        }
        foreach ($file in 'LICENSE', 'THIRD_PARTY_NOTICES.md') {
            $source = Join-Path $unpacked $file
            if (Test-Path $source) { Copy-Item $source (Join-Path $InstallDir $file) -Force }
        }
    } finally {
        Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $exe = Join-Path $InstallDir 'emerald.exe'
    $installed = & $exe --version
    if ($LASTEXITCODE -ne 0 -or -not $installed) {
        Fail "Emerald was downloaded to $InstallDir, but it does not run on this machine"
    }
    Write-Host "Installed $installed to $exe"

    $entries = Split-PathList (Get-UserPath)
    if (-not ($entries | Where-Object { Test-SameFolder $_ $InstallDir })) {
        Set-UserPath ((@($entries) + $InstallDir) -join ';')
        Write-Host "Added $InstallDir to your PATH"
    }
    # This window, too, so `emerald` works here straight away.
    if (-not (Split-PathList $env:Path | Where-Object { Test-SameFolder $_ $InstallDir })) {
        $env:Path = "$env:Path;$InstallDir"
    }

    Write-Host ''
    Write-Host 'Emerald is ready. Try: emerald --version' -ForegroundColor Green
    Write-Host 'Other open terminals, and editors such as VS Code, need restarting to find it.'
}

try {
    Install-Emerald
} catch {
    Write-Host "emerald install: $($_.Exception.Message)" -ForegroundColor Red
    $global:LASTEXITCODE = 1
}
