#!/usr/bin/env bash
set -e

REPO="la-rebelion/hapimcp"
BINARY="hapi"
DEFAULT_VERSION="v0.2.1"

# Function to fetch the latest version from GitHub
fetch_latest_version() {
  echo "Fetching latest version information..."
  LATEST_VERSION=$(curl -fsSL "https://raw.githubusercontent.com/$REPO/refs/heads/main/latest" | tr -d '[:space:]')
  
  if [[ -z "$LATEST_VERSION" ]]; then
    echo "Could not fetch latest version, falling back to default: $DEFAULT_VERSION"
    echo "$DEFAULT_VERSION"
  else
    echo "Latest version: $LATEST_VERSION"
    echo "$LATEST_VERSION"
  fi
}

# Parse arguments for --version
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# If no version specified, fetch the latest version
if [[ -z "$VERSION" ]]; then
  VERSION=$(fetch_latest_version || echo "$DEFAULT_VERSION")
fi

detect_platform() {
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  case $ARCH in
    x86_64) ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
  esac

  case $OS in
    linux) OS="linux" ;;
    darwin) OS="darwin" ;;
    msys|mingw*|cygwin) OS="windows" ;;
    *) echo "Unsupported OS: $OS"; exit 1 ;;
  esac

  echo "${ARCH}-${OS}"
}

download_and_verify() {
  PLATFORM=$(detect_platform)
  EXT=""
  BIN_NAME="${BINARY}-${VERSION#v}-${PLATFORM}"
  if [[ "$PLATFORM" == *windows ]]; then
    BIN_NAME="${BIN_NAME}.exe"
    EXT=".exe"
  fi

  ARCHIVE="${BIN_NAME}.gz"
  CHECKSUM="${ARCHIVE}.sha256"
  BASE_URL="https://github.com/$REPO/releases/download/$VERSION"

  echo "Installing $BINARY version $VERSION for $PLATFORM"
  echo "Downloading $ARCHIVE and $CHECKSUM from $BASE_URL"

  curl -fsSL "$BASE_URL/$ARCHIVE" -o "$ARCHIVE"
  curl -fsSL "$BASE_URL/$CHECKSUM" -o "$CHECKSUM"

  echo "Verifying checksum..."
  sha256sum -c "$CHECKSUM"

  echo "Extracting binary..."
  gunzip -c "$ARCHIVE" > "$BINARY$EXT"
  chmod +x "$BINARY$EXT"

  if [[ "$PLATFORM" == *windows ]]; then
    mv "$BINARY$EXT" "/usr/local/bin/$BINARY$EXT"
  else
    mv "$BINARY$EXT" "/usr/local/bin/$BINARY"
  fi

  echo "$BINARY installed successfully!"
  "/usr/local/bin/$BINARY$EXT" --version || true
}

setup_env() {
  HAPI_HOME="$HOME/.hapi"
  mkdir -p "$HAPI_HOME/config" "$HAPI_HOME/specs" "$HAPI_HOME/src" "$HAPI_HOME/certs"
  echo "Created HAPI environment at $HAPI_HOME"
}

example_commands() {
  echo -e "\nExample commands:"
  echo "  $BINARY --help"
  echo "  $BINARY --version"
  echo "  $BINARY <command>"
  echo "  $BINARY serve strava --headless"
}

download_and_verify
setup_env
example_commands