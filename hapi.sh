#!/usr/bin/env bash
set -e

BINARY="hapi"

# v0.x releases live in the legacy repo; v1.x+ releases moved to a new repo
LEGACY_REPO="la-rebelion/hapimcp"
LEGACY_PKG_NAME="@la-rebelion-$BINARY"
LEGACY_DEFAULT_VERSION="v0.7.1"

NEW_REPO="mcp-com-ai/hapimcp"
NEW_PKG_NAME="@mcp-com-ai-$BINARY"
NEW_DEFAULT_VERSION="v1.0.0-beta.0823"

REPO="$LEGACY_REPO"
PKG_NAME="$LEGACY_PKG_NAME"
DEFAULT_VERSION="$LEGACY_DEFAULT_VERSION"

# Function to fetch the latest version from GitHub
fetch_latest_version() {
  local app_name="${1:-hapi}"
  local fallback_version="${2:-$DEFAULT_VERSION}"
  echo "Fetching latest version information for $app_name..." >&2
  local latest_content
  latest_content=$(curl -fsSL "https://raw.githubusercontent.com/la-rebelion/be-hapi/refs/heads/main/latest" || true)

  if [[ -z "$latest_content" ]]; then
    echo "Could not fetch latest version, falling back to default: $fallback_version" >&2
    echo "$fallback_version"
    return
  fi

  # Extract version for the requested app (format: name:version), trim spaces
  local raw_version
  raw_version=$(printf '%s\n' "$latest_content" | awk -F: -v app="$app_name" '$1==app {print $2}' | head -n1 | tr -d '[:space:]')

  if [[ -z "$raw_version" ]]; then
    echo "No version found for $app_name, falling back to default: $fallback_version" >&2
    echo "$fallback_version"
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

# If no version specified, fetch the latest v0.x version of hapi
if [[ -z "$VERSION" ]]; then
  VERSION=$(fetch_latest_version "hapi" "$LEGACY_DEFAULT_VERSION")
fi

# Allow shorthand "1"/"v1" to fetch the latest v1.x+ release, tracked under the "hapiv1" channel key
if [[ "$VERSION" == "1" || "$VERSION" == "v1" ]]; then
  VERSION=$(fetch_latest_version "hapiv1" "$NEW_DEFAULT_VERSION")
fi

# v1.x+ releases are published in a different GitHub repo; switch targets accordingly
MAJOR_VERSION="${VERSION#v}"
MAJOR_VERSION="${MAJOR_VERSION%%.*}"
if [[ "$MAJOR_VERSION" =~ ^[0-9]+$ ]] && (( MAJOR_VERSION >= 1 )); then
  REPO="$NEW_REPO"
  PKG_NAME="$NEW_PKG_NAME"
  echo "Version '$VERSION' is v1+, using repository: $REPO" >&2
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

# Detect whether the host CPU exposes AVX2. The default Linux x86_64 build is compiled
# with AVX2 codegen for performance; VMs/hypervisors that don't pass AVX2 through to the
# guest crash it with "Illegal instruction (core dumped)" on first use. Fall back to the
# baseline (no-AVX2) build in that case.
supports_avx2() {
  [[ -r /proc/cpuinfo ]] && grep -qo '\bavx2\b' /proc/cpuinfo
}

detect_platform() {
  OS=$(uname | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)
  local is_v1=false
  local v1_arch

  if [[ "$MAJOR_VERSION" =~ ^[0-9]+$ ]] && (( MAJOR_VERSION >= 1 )); then
    is_v1=true
  fi

  case $ARCH in
    x86_64) ARCH="x86_64"; v1_arch="x64" ;;
    arm64|aarch64) ARCH="aarch64"; v1_arch="arm64" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
  esac

  case $OS in
    linux) OS="linux" ;;
    darwin) OS="darwin" ;;
    msys|mingw*|cygwin) OS="windows" ;;
    *) echo "Unsupported OS: $OS"; exit 1 ;;
  esac

  local suffix=""
  if [[ "$OS" == "linux" && "$ARCH" == "x86_64" ]] && ! supports_avx2; then
    echo "CPU does not support AVX2; using the baseline build for compatibility." >&2
    suffix="-baseline"
  fi

  if [[ "$is_v1" == true ]]; then
    if [[ "$OS" == "linux" && "$ARCH" == "x86_64" && -z "$suffix" ]]; then
      suffix="-modern"
    elif [[ "$OS" == "linux" && "$ARCH" == "aarch64" ]]; then
      suffix="-musl"
    fi
    echo "${OS}-${v1_arch}${suffix}"
    return
  fi

  echo "${ARCH}-${OS}${suffix}"
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
cleanup() {
  rm -f "${BIN_NAME}.gz" "${BIN_NAME}.gz.sha256"
}
trap cleanup EXIT