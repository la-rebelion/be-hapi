#!/usr/bin/env bash
set -e

REPO="la-rebelion/qbot-cli"
PKG_NAME="qbot"
BINARY="qbot"
DEFAULT_VERSION="v0.1.0"

# Function to fetch the latest version from GitHub
fetch_latest_version() {
  echo "Fetching latest version information..." >&2
  local app_name="${1:-qbot}"
  local latest_content
  latest_content=$(curl -fsSL "https://raw.githubusercontent.com/la-rebelion/be-hapi/refs/heads/main/latest" || true)

  if [[ -z "$latest_content" ]]; then
    echo "Could not fetch latest version, falling back to default: $DEFAULT_VERSION" >&2
    echo "$DEFAULT_VERSION"
    return
  fi

  # Extract version for the requested app (format: name:version), trim spaces
  local raw_version
  raw_version=$(printf '%s\n' "$latest_content" | awk -F: -v app="$app_name" '$1==app {print $2}' | head -n1 | tr -d '[:space:]')

  if [[ -z "$raw_version" ]]; then
    echo "No version found for $app_name, falling back to default: $DEFAULT_VERSION" >&2
    echo "$DEFAULT_VERSION"
  else
    # Normalize to v-prefixed version to match release tags
    if [[ "$raw_version" != v* ]]; then
      raw_version="v${raw_version}"
    fi
    echo "Latest $app_name version: $raw_version" >&2
    echo "$raw_version"
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

# If no version specified, fetch the latest version of qbot
if [[ -z "$VERSION" ]]; then
  VERSION=$(fetch_latest_version "qbot" || echo "$DEFAULT_VERSION")
fi

# Verify the requested version actually exists as a GitHub release before attempting download
verify_version_exists() {
  local api_url="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" "$api_url")

  if [[ "$http_code" == "404" ]]; then
    echo "Error: Version '$VERSION' was not found in the '$REPO' repository." >&2
    echo "Check the available releases at: https://github.com/$REPO/releases" >&2
    exit 1
  elif [[ "$http_code" != "200" ]]; then
    echo "Error: Could not verify version '$VERSION' (GitHub API returned HTTP $http_code)." >&2
    echo "This may be a network issue or GitHub API rate limiting. Try again shortly." >&2
    exit 1
  fi
}

verify_version_exists

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
  BIN_NAME="${PKG_NAME}-${VERSION#v}-${PLATFORM}"
  if [[ "$PLATFORM" == *windows ]]; then
    BIN_NAME="${PKG_NAME}.exe"
    EXT=".exe"
  fi

  ARCHIVE="${BIN_NAME}.gz"
  CHECKSUM="${ARCHIVE}.sha256"
  BASE_URL="https://github.com/$REPO/releases/download/$VERSION"

  echo "Installing $BINARY version $VERSION for $PLATFORM"
  echo "Downloading $ARCHIVE and $CHECKSUM from $BASE_URL"

  if ! curl -fsSL "$BASE_URL/$ARCHIVE" -o "$ARCHIVE"; then
    echo "Error: Failed to download '$ARCHIVE' for version '$VERSION'." >&2
    echo "URL attempted: $BASE_URL/$ARCHIVE" >&2
    echo "This usually means there is no build for platform '$PLATFORM' in that release." >&2
    echo "Check available assets at: https://github.com/$REPO/releases/tag/$VERSION" >&2
    exit 1
  fi

  if ! curl -fsSL "$BASE_URL/$CHECKSUM" -o "$CHECKSUM"; then
    echo "Error: Failed to download checksum file '$CHECKSUM' for version '$VERSION'." >&2
    echo "URL attempted: $BASE_URL/$CHECKSUM" >&2
    exit 1
  fi

  echo "Verifying checksum..."
  if ! sha256sum -c "$CHECKSUM"; then
    echo "Error: Checksum verification failed for '$ARCHIVE'. The downloaded file may be corrupted." >&2
    exit 1
  fi

  echo "Extracting binary..."
  gunzip -c "$ARCHIVE" > "$BINARY$EXT"
  chmod +x "$BINARY$EXT"

  INSTALL_PATH="/usr/local/bin"
  if [[ "$PLATFORM" == *windows ]]; then
    if ! mv "$BINARY$EXT" "$INSTALL_PATH/$BINARY$EXT" 2>/dev/null; then
      mkdir -p "$HOME/bin"
      mv "$BINARY$EXT" "$HOME/bin/$BINARY$EXT"
      INSTALL_PATH="$HOME/bin"
      echo "Installed to $INSTALL_PATH (no write permission for /usr/local/bin)"
    fi
  else
    if ! mv "$BINARY$EXT" "$INSTALL_PATH/$BINARY" 2>/dev/null; then
      mkdir -p "$HOME/bin"
      mv "$BINARY$EXT" "$HOME/bin/$BINARY"
      INSTALL_PATH="$HOME/bin"
      echo "Installed to $INSTALL_PATH (no write permission for /usr/local/bin)"
    fi
  fi

  echo "$BINARY installed successfully!"
  echo "Testing installation... version output below:"
  "$INSTALL_PATH/$BINARY$EXT" --version || true
}

setup_env() {
  QBOT_HOME="$HOME/.qbot"
  mkdir -p "$QBOT_HOME/config" "$QBOT_HOME/specs" "$QBOT_HOME/src" "$QBOT_HOME/certs"
  echo "Created QBot environment at $QBOT_HOME"
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
cleanup() {
  rm -f "${BIN_NAME}.gz" "${BIN_NAME}.gz.sha256"
}
trap cleanup EXIT