param(
    [string] $Version = $env:ADTENTION_VERSION,
    [string] $InstallRoot = $env:ADTENTION_INSTALL_ROOT,
    [string] $ReleaseBase = $env:ADTENTION_RELEASE_BASE
)

$ErrorActionPreference = "Stop"

$Repo = "adtention-ai/terminal"
$RuntimeAsset = "adtention-terminal-runtime.tar.gz"
$SumsAsset = "SHA256SUMS"

function Write-AdtentionLog {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    Write-Host "adtention-terminal: $Message"
}

function Get-AdtentionDefaultInstallRoot {
    return (Join-Path $HOME ".adtention-terminal")
}

function Resolve-AdtentionVersion {
    if ($Version) {
        return $Version
    }

    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest"
    if (-not $release.tag_name) {
        throw "could not resolve latest release version"
    }

    return [string] $release.tag_name
}

function Get-AdtentionOS {
    if ($env:OS -eq "Windows_NT") {
        return "windows"
    }

    $uname = (& uname -s).ToLowerInvariant()
    switch ($uname) {
        "darwin" { return "darwin" }
        "linux" { return "linux" }
        default { throw "unsupported OS: $uname" }
    }
}

function Get-AdtentionArch {
    try {
        $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    } catch {
        $arch = $env:PROCESSOR_ARCHITECTURE
        if (-not $arch) {
            $arch = (& uname -m)
        }
        $arch = $arch.ToLowerInvariant()
    }

    switch ($arch) {
        "x64" { return "amd64" }
        "x86_64" { return "amd64" }
        "amd64" { return "amd64" }
        "arm64" { return "arm64" }
        "aarch64" { return "arm64" }
        default { throw "unsupported CPU architecture: $arch" }
    }
}

function Get-AdtentionPlatformAssetName {
    $os = Get-AdtentionOS
    $arch = Get-AdtentionArch
    $ext = if ($os -eq "windows") { ".exe" } else { "" }
    return "adtention-terminal-$os-$arch$ext"
}

function Get-AdtentionAssetUri {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $ResolvedVersion
    )

    if ($ReleaseBase) {
        return "$($ReleaseBase.TrimEnd('/'))/$Name"
    }

    return "https://github.com/$Repo/releases/download/$ResolvedVersion/$Name"
}

function Save-AdtentionAsset {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Destination,

        [Parameter(Mandatory = $true)]
        [string] $ResolvedVersion
    )

    $uri = Get-AdtentionAssetUri -Name $Name -ResolvedVersion $ResolvedVersion
    if ($uri -like "file://*") {
        $source = ([System.Uri] $uri).LocalPath
        Copy-Item -LiteralPath $source -Destination $Destination -Force
        return
    }

    Invoke-WebRequest -Uri $uri -OutFile $Destination -UseBasicParsing
}

function Get-AdtentionExpectedChecksum {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $SumsPath
    )

    foreach ($line in Get-Content -LiteralPath $SumsPath) {
        $parts = $line.Trim() -split "\s+", 2
        if ($parts.Count -lt 2) {
            continue
        }

        $file = Split-Path -Leaf $parts[1].TrimStart("*")
        if ($file -eq $Name) {
            return $parts[0].ToLowerInvariant()
        }
    }

    throw "$SumsAsset does not list $Name"
}

function Assert-AdtentionChecksum {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Name,

        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $SumsPath
    )

    $expected = Get-AdtentionExpectedChecksum -Name $Name -SumsPath $SumsPath
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
    if ($expected -ne $actual) {
        throw "checksum mismatch for $Name"
    }
}

function Add-AdtentionPathForCurrentProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string] $BinDir
    )

    $paths = @($env:Path -split [System.IO.Path]::PathSeparator)
    if ($paths -notcontains $BinDir) {
        $env:Path = $BinDir + [System.IO.Path]::PathSeparator + $env:Path
    }
}

if (-not $InstallRoot) {
    $InstallRoot = Get-AdtentionDefaultInstallRoot
}

$resolvedVersion = Resolve-AdtentionVersion
$platformAsset = Get-AdtentionPlatformAssetName
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "adtention-terminal-install-$([System.Guid]::NewGuid().ToString('N'))"

New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    Write-AdtentionLog "installing $resolvedVersion into $InstallRoot"

    $sumsPath = Join-Path $tmp $SumsAsset
    $runtimePath = Join-Path $tmp $RuntimeAsset
    $platformPath = Join-Path $tmp $platformAsset

    Save-AdtentionAsset -Name $SumsAsset -Destination $sumsPath -ResolvedVersion $resolvedVersion
    Save-AdtentionAsset -Name $RuntimeAsset -Destination $runtimePath -ResolvedVersion $resolvedVersion
    Save-AdtentionAsset -Name $platformAsset -Destination $platformPath -ResolvedVersion $resolvedVersion

    Assert-AdtentionChecksum -Name $RuntimeAsset -Path $runtimePath -SumsPath $sumsPath
    Assert-AdtentionChecksum -Name $platformAsset -Path $platformPath -SumsPath $sumsPath

    $binDir = Join-Path $InstallRoot "bin"
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    tar -xzf $runtimePath -C $InstallRoot
    if ($LASTEXITCODE -ne 0) {
        throw "failed to extract runtime package"
    }

    $assetDestination = Join-Path $binDir $platformAsset
    Copy-Item -LiteralPath $platformPath -Destination $assetDestination -Force
    Copy-Item -LiteralPath $sumsPath -Destination (Join-Path $binDir $SumsAsset) -Force

    if ((Get-AdtentionOS) -eq "windows") {
        Copy-Item -LiteralPath $platformPath -Destination (Join-Path $binDir "adtention-terminal.exe") -Force
    } else {
        chmod +x $assetDestination
        chmod +x (Join-Path $binDir "adtention-terminal")
    }

    $env:ADTENTION_INSTALL_ROOT = $InstallRoot
    Add-AdtentionPathForCurrentProcess -BinDir $binDir

    & (Join-Path $InstallRoot "scripts/install-shell-integration.ps1")

    Write-AdtentionLog "installed. Open a new terminal, or run: `$env:Path = '$binDir' + [System.IO.Path]::PathSeparator + `$env:Path"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
