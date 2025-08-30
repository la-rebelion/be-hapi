# HAPI PowerShell Installer Script

$Repo = "la-rebelion/hapimcp"
$Binary = "hapi"
$DefaultVersion = "v0.2.1"
$Version = $null

# Function to fetch the latest version from GitHub
function Get-LatestVersion {
    Write-Host "Fetching latest version information..."
    try {
        $LatestVersion = (Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/refs/heads/main/latest" -UseBasicParsing).Content.Trim()
        
        if ([string]::IsNullOrWhiteSpace($LatestVersion)) {
            Write-Host "Could not fetch latest version, falling back to default: $DefaultVersion"
            return $DefaultVersion
        } else {
            Write-Host "Latest version: $LatestVersion"
            return $LatestVersion
        }
    } catch {
        Write-Host "Error fetching latest version, falling back to default: $DefaultVersion"
        return $DefaultVersion
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

# If no version specified, fetch the latest version
if (-not $Version) {
    $Version = Get-LatestVersion
}

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
    $BinName = "$Binary-$($Version.TrimStart('v'))-$Platform.exe"
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
    
    Invoke-WebRequest -Uri "$BaseUrl/$Archive" -OutFile $ArchivePath -UseBasicParsing
    Invoke-WebRequest -Uri "$BaseUrl/$Checksum" -OutFile $ChecksumPath -UseBasicParsing

    # Verify checksum
    Write-Host "Verifying checksum..."
    $ExpectedChecksum = Get-Content $ChecksumPath | ForEach-Object { $_.Split(' ')[0] }
    $ActualChecksum = (Get-FileHash -Algorithm SHA256 -Path $ArchivePath).Hash.ToLower()
    
    if ($ExpectedChecksum -ne $ActualChecksum) {
        Write-Error "Checksum verification failed. Expected: $ExpectedChecksum, Got: $ActualChecksum"
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
