# HAPI PowerShell Installer Script

$LatestUrl = "https://raw.githubusercontent.com/la-rebelion/be-hapi/refs/heads/main/latest"
$Binary = "hapi"

# v0.x releases live in the legacy repo; v1.x+ releases moved to a new repo
$LegacyRepo = "la-rebelion/hapimcp"
$LegacyPkgName = "@la-rebelion-$Binary"
$LegacyDefaultVersion = "v0.7.1"

$NewRepo = "mcp-com-ai/hapimcp"
$NewPkgName = "@mcp-com-ai-$Binary"
$NewDefaultVersion = "v1.0.0-beta.0823"

$Repo = $LegacyRepo
$PkgName = $LegacyPkgName
$DefaultVersion = $LegacyDefaultVersion
$Version = $null

# Function to fetch the latest version from GitHub for a given channel key (e.g. "hapi", "hapiv1")
function Get-LatestVersion {
    param(
        [string]$AppName = "hapi",
        [string]$Fallback = $LegacyDefaultVersion
    )
    Write-Host "Fetching latest version information for $AppName..."
    try {
        $content = (Invoke-WebRequest -Uri $LatestUrl -UseBasicParsing).Content

        if ([string]::IsNullOrWhiteSpace($content)) {
            Write-Host "Could not fetch latest version, falling back to default: $Fallback"
            return $Fallback
        }

        # Extract version for the requested app from lines like: name:version (exact key match)
        $line = ($content -split "`n") | Where-Object { ($_ -split ':')[0].Trim() -eq $AppName } | Select-Object -First 1
        if (-not $line) {
            Write-Host "No version found for $AppName, falling back to default: $Fallback"
            return $Fallback
        }

        $rawVersion = ($line -split ':')[1].Trim()
        if ([string]::IsNullOrWhiteSpace($rawVersion)) {
            Write-Host "No version found for $AppName, falling back to default: $Fallback"
            return $Fallback
        }

        if (-not $rawVersion.StartsWith('v')) {
            $rawVersion = "v$rawVersion"
        }

        Write-Host "Latest $AppName version: $rawVersion"
        return $rawVersion
    } catch {
        Write-Host "Error fetching latest version, falling back to default: $Fallback"
        return $Fallback
    }
}

# Parse command line arguments
$args = $args
for ($i = 0; $i -lt $args.Count; $i++) {
    if ($args[$i] -eq "--version" -and $i+1 -lt $args.Count) {
        $Version = $args[$i+1]
        $i++
    }
}

# If no version specified, fetch the latest v0.x version
if (-not $Version) {
    $Version = Get-LatestVersion -AppName "hapi" -Fallback $LegacyDefaultVersion
}

# Allow shorthand "1"/"v1" to fetch the latest v1.x+ release, tracked under the "hapiv1" channel key
if ($Version -eq "1" -or $Version -eq "v1") {
    $Version = Get-LatestVersion -AppName "hapiv1" -Fallback $NewDefaultVersion
}

# v1.x+ releases are published in a different GitHub repo; switch targets accordingly
$MajorVersion = $Version.TrimStart('v').Split('.')[0]
if ($MajorVersion -match '^\d+$' -and [int]$MajorVersion -ge 1) {
    $Repo = $NewRepo
    $PkgName = $NewPkgName
    Write-Host "Version '$Version' is v1+, using repository: $Repo"
}

# Verify the requested version actually exists as a GitHub release before attempting download
function Confirm-VersionExists {
    $ApiUrl = "https://api.github.com/repos/$Repo/releases/tags/$Version"
    try {
        Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -Headers @{ "User-Agent" = "hapi-installer" } | Out-Null
    } catch {
        $StatusCode = $null
        if ($_.Exception.Response) {
            $StatusCode = [int]$_.Exception.Response.StatusCode
        }
        if ($StatusCode -eq 404) {
            Write-Error "Version '$Version' was not found in the '$Repo' repository. Check available releases at: https://github.com/$Repo/releases"
        } else {
            Write-Error "Could not verify version '$Version' (HTTP $StatusCode). This may be a network issue or GitHub API rate limiting."
        }
        exit 1
    }
}

Confirm-VersionExists

# Detect platform
function Get-Platform {
    $arch = [System.Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
    
    if ($arch -eq "AMD64") {
        return "x86_64-windows"
    } elseif ($arch -eq "ARM64") {
        return "aarch64-windows"
    } else {
        Write-Error "Unsupported architecture: $arch"
        exit 1
    }
}

# Download and verify the binary
function Install-Binary {
    $Platform = Get-Platform
    $BinName = "$PkgName-$($Version.TrimStart('v'))-$Platform.exe"
    $Archive = "$BinName.gz"
    $Checksum = "$Archive.sha256"
    $BaseUrl = "https://github.com/$Repo/releases/download/$Version"

    Write-Host "Installing $Binary version $Version for $Platform"
    Write-Host "Downloading $Archive and $Checksum from $BaseUrl"

    # Create temp directory
    $TempDir = [System.IO.Path]::GetTempPath() + [System.Guid]::NewGuid().ToString()
    New-Item -ItemType Directory -Path $TempDir | Out-Null
    
    # Download files
    $ArchivePath = Join-Path $TempDir $Archive
    $ChecksumPath = Join-Path $TempDir $Checksum

    try {
        Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile $ArchivePath -UseBasicParsing
        Invoke-WebRequest -Uri "$BaseUrl/$Checksum" -OutFile $ChecksumPath -UseBasicParsing
    } catch {
        Write-Error "Failed to download version '$Version' for platform '$Platform'. This usually means there is no build for your platform in that release. Check available assets at: https://github.com/$Repo/releases/tag/$Version"
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }

    # Verify checksum
    Write-Host "Verifying checksum..."
    $ExpectedChecksum = Get-Content $ChecksumPath | ForEach-Object { $_.Split(' ')[0] }
    $ActualChecksum = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLower()
    
    if ($ExpectedChecksum -ne $ActualChecksum) {
        Write-Error "Checksum verification failed. Expected: $ExpectedChecksum, Got: $ActualChecksum. The downloaded file may be corrupted."
        Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
    
    Write-Host "Checksum verified!"

    # Extract binary
    Write-Host "Extracting binary..."
    $BinaryPath = Join-Path $TempDir $Binary
    
    # Use .NET's GZipStream to decompress
    $input = New-Object System.IO.FileStream $ArchivePath, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::Read)
    $output = New-Object System.IO.FileStream $BinaryPath, ([IO.FileMode]::Create), ([IO.FileAccess]::Write), ([IO.FileShare]::None)
    $gzipStream = New-Object System.IO.Compression.GZipStream $input, ([IO.Compression.CompressionMode]::Decompress)
    
    $buffer = New-Object byte[](1024)
    while ($true) {
        $read = $gzipStream.Read($buffer, 0, 1024)
        if ($read -le 0) { break }
        $output.Write($buffer, 0, $read)
    }
    
    $gzipStream.Close()
    $output.Close()
    $input.Close()
    
    # Install binary
    $InstallDir = "$env:LOCALAPPDATA\Programs\hapi"
    $DestPath = "$InstallDir\$Binary.exe"
    
    # Create install directory if it doesn't exist
    if (-not (Test-Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir | Out-Null
    }
    
    # Move binary to install location
    Move-Item -Path $BinaryPath -Destination $DestPath -Force
    
    # Add to PATH if not already there
    $UserPath = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    if (-not $UserPath.Contains($InstallDir)) {
        [System.Environment]::SetEnvironmentVariable(
            "PATH", 
            "$UserPath;$InstallDir", 
            "User"
        )
        $env:PATH = "$env:PATH;$InstallDir"
    }
    
    Write-Host "$Binary installed successfully at $DestPath!"
    
    try {
        & "$DestPath" --version
    } catch {
        Write-Host "Could not execute version check, but installation completed."
    }
    
    # Clean up
    Remove-Item -Path $TempDir -Recurse -Force
}

# Setup environment
function Initialize-Environment {
    $HapiHome = "$env:USERPROFILE\.hapi"
    
    if (-not (Test-Path $HapiHome)) {
        New-Item -ItemType Directory -Path $HapiHome | Out-Null
    }
    
    $Folders = @("config", "specs", "src", "certs")
    foreach ($Folder in $Folders) {
        $Path = Join-Path $HapiHome $Folder
        if (-not (Test-Path $Path)) {
            New-Item -ItemType Directory -Path $Path | Out-Null
        }
    }
    
    Write-Host "Created HAPI environment at $HapiHome"
}

# Example commands
function Show-Examples {
    Write-Host "`nExample commands:"
    Write-Host "  $Binary --help"
    Write-Host "  $Binary --version"
    Write-Host "  $Binary <command>"
    Write-Host "  $Binary serve strava --headless"
}

# Main execution
Install-Binary
Initialize-Environment
Show-Examples
