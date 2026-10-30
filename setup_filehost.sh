#!/bin/bash
# setup_filehost.sh - Build and deploy FileHost service to an Adaptix Server directory.
#
# Builds the FileHost Go plugin, deploys to Server/extenders/file_host/,
# syncs go.mod to match the server's axc2 module, and registers in profile.yaml.
#
# Usage:
#   ./setup_filehost.sh --server /path/to/Server
#   ./setup_filehost.sh --server /path/to/Server --adaptix-src /path/to/AdaptixC2

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

error_exit()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info_msg()    { echo -e "${GREEN}[+]${NC} $1"; }
warning_msg() { echo -e "${YELLOW}[!]${NC} $1"; }
step_msg()    { echo -e "${CYAN}[*]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR=""
ADAPTIX_SRC=""
GO_BIN=""
GOEXPERIMENT=""
SERVER_GO_VERSION=""
SERVER_AXC2_MODULE=""
SERVER_AXC2_VERSION=""

## ========= [ argument parsing ] =========

while [[ $# -gt 0 ]]; do
    case $1 in
        --server)
            SERVER_DIR="$(realpath "$2" 2>/dev/null || echo "$2")"
            shift 2
            ;;
        --adaptix-src)
            ADAPTIX_SRC="$(realpath "$2" 2>/dev/null || echo "$2")"
            shift 2
            ;;
        -h|--help)
            cat <<EOF
Usage: $0 --server <Server_directory> [--adaptix-src <dir>]

Required:
  --server <dir>      Path to Adaptix Server directory
                      (contains adaptixserver binary, extenders/, profile.yaml)

Optional:
  --adaptix-src <dir> Path to Adaptix source tree (contains AdaptixServer/go.mod).
                      Used to detect axc2 module version for plugin sync.
                      If omitted, auto-searches common locations.

Examples:
  $0 --server /opt/post-exploitation/Original/AdaptixC2/dist
  $0 --server /opt/Server --adaptix-src /opt/AdaptixC2
EOF
            exit 0
            ;;
        *)
            error_exit "Unknown parameter: $1\nRun $0 --help for usage."
            ;;
    esac
done

if [ -z "$SERVER_DIR" ]; then
    error_exit "Missing required --server argument.\nRun $0 --help for usage."
fi

## ========= [ validate server directory ] =========

if [ ! -d "$SERVER_DIR" ]; then
    error_exit "Server directory does not exist: $SERVER_DIR"
fi

if [ ! -f "$SERVER_DIR/adaptixserver" ] && [ ! -f "$SERVER_DIR/profile.yaml" ]; then
    error_exit "Not an Adaptix Server directory (no adaptixserver or profile.yaml): $SERVER_DIR"
fi

EXTENDERS_DIR="$SERVER_DIR/extenders"
DEPLOY_DIR="$EXTENDERS_DIR/file_host"

## ========= [ find Go binary ] =========

find_go() {
    if [ -x /usr/local/go/bin/go ]; then
        GO_BIN="/usr/local/go/bin/go"
    elif command -v go >/dev/null 2>&1; then
        GO_BIN="$(command -v go)"
    else
        error_exit "Go compiler not found. Install Go and re-run."
    fi
    info_msg "Go: $($GO_BIN version 2>/dev/null | head -1)"
}

## ========= [ GOEXPERIMENT auto-detection ] =========

detect_goexperiment() {
    local server_bin="$SERVER_DIR/adaptixserver"
    if [ ! -f "$server_bin" ]; then
        warning_msg "adaptixserver binary not found - building without GOEXPERIMENT"
        GOEXPERIMENT=""
        return
    fi

    local version_line
    version_line=$($GO_BIN version "$server_bin" 2>/dev/null | head -1)

    if echo "$version_line" | grep -qP 'X:'; then
        GOEXPERIMENT=$(echo "$version_line" | grep -oP '(?<=X:)\S+')
        info_msg "Detected GOEXPERIMENT=$GOEXPERIMENT"
    else
        GOEXPERIMENT=""
        info_msg "Server built without GOEXPERIMENT (plain $(echo "$version_line" | grep -oP 'go\d+\.\d+\.\d+'))"
    fi
}

## ========= [ Go version detection from server binary ] =========

detect_go_version() {
    local server_bin="$SERVER_DIR/adaptixserver"
    if [ ! -f "$server_bin" ]; then
        return
    fi

    local version_line
    version_line=$(strings "$server_bin" 2>/dev/null | grep -oP '^go\d+\.\d+\.\d+' | head -1)

    if [ -z "$version_line" ]; then
        return
    fi

    SERVER_GO_VERSION="${version_line#go}"
    info_msg "Server Go version: $SERVER_GO_VERSION"

    local local_go_version
    local_go_version=$($GO_BIN version 2>/dev/null | grep -oP 'go\d+\.\d+\.\d+' | head -1)
    local_go_version="${local_go_version#go}"

    if [ "$local_go_version" != "$SERVER_GO_VERSION" ]; then
        warning_msg "Go version MISMATCH: local=$local_go_version server=$SERVER_GO_VERSION"
        warning_msg "Plugin may fail to load. Install go$SERVER_GO_VERSION to match."
    else
        info_msg "Go version match: $local_go_version"
    fi
}

## ========= [ Adaptix source auto-discovery ] =========

find_adaptix_src() {
    if [ -n "$ADAPTIX_SRC" ] && [ -f "$ADAPTIX_SRC/AdaptixServer/go.mod" ]; then
        return
    fi
    if [ -n "$ADAPTIX_SRC" ] && [ -f "$ADAPTIX_SRC/go.mod" ]; then
        ADAPTIX_SRC="$(dirname "$ADAPTIX_SRC")"
        return
    fi

    local search_paths=(
        "/opt/post-exploitation/Original/AdaptixC2"
        "$(dirname "$SCRIPT_DIR")/Original/AdaptixC2"
        "$(dirname "$(dirname "$SCRIPT_DIR")")/AdaptixC2"
        "$HOME/AdaptixC2"
    )

    for path in "${search_paths[@]}"; do
        if [ -f "$path/AdaptixServer/go.mod" ]; then
            ADAPTIX_SRC="$path"
            info_msg "Found Adaptix source at: $ADAPTIX_SRC"
            return
        fi
    done

    warning_msg "Adaptix source not found. Use --adaptix-src to specify location."
}

## ========= [ axc2 module detection ] =========

detect_axc2_module() {
    local server_gomod=""

    if [ -n "$ADAPTIX_SRC" ] && [ -f "$ADAPTIX_SRC/AdaptixServer/go.mod" ]; then
        server_gomod="$ADAPTIX_SRC/AdaptixServer/go.mod"
    fi

    if [ -n "$server_gomod" ]; then
        local axc2_line
        axc2_line=$(grep 'github.com/Adaptix-Framework/axc2' "$server_gomod" | grep -v '//' | head -1)

        if [ -n "$axc2_line" ]; then
            SERVER_AXC2_MODULE=$(echo "$axc2_line" | awk '{print $1}')
            SERVER_AXC2_VERSION=$(echo "$axc2_line" | awk '{print $2}')
            info_msg "Detected axc2 module: $SERVER_AXC2_MODULE@$SERVER_AXC2_VERSION"
            return
        fi
    fi

    local server_bin="$SERVER_DIR/adaptixserver"
    if [ -f "$server_bin" ]; then
        local mod_info
        mod_info=$(strings "$server_bin" 2>/dev/null | grep -m1 'github.com/Adaptix-Framework/axc2')
        if [ -n "$mod_info" ]; then
            SERVER_AXC2_MODULE=$(echo "$mod_info" | awk '{print $1}')
            SERVER_AXC2_VERSION=$(echo "$mod_info" | awk '{print $2}')
            if [ -n "$SERVER_AXC2_MODULE" ] && [ -n "$SERVER_AXC2_VERSION" ]; then
                info_msg "Detected axc2 (from binary): $SERVER_AXC2_MODULE@$SERVER_AXC2_VERSION"
                return
            fi
        fi
    fi

    warning_msg "Could not detect axc2 module version"
}

## ========= [ Go module sync ] =========

sync_go_modules() {
    find_adaptix_src
    detect_axc2_module

    if [ -z "$SERVER_AXC2_MODULE" ] || [ -z "$SERVER_AXC2_VERSION" ]; then
        warning_msg "Cannot sync: unable to determine server's axc2 module version."
        warning_msg "Use --adaptix-src to specify location. Skipping module sync."
        return
    fi

    local go_directive="${SERVER_GO_VERSION:-1.26.5}"

    local current_module
    current_module=$(grep -oP 'github\.com/Adaptix-Framework/axc2(/v\d+)?' "$SCRIPT_DIR/go.mod" | head -1)
    local current_version
    current_version=$(grep 'github.com/Adaptix-Framework/axc2' "$SCRIPT_DIR/go.mod" | grep -v '//' | head -1 | grep -oP 'v\d+\.\d+\.\d+')

    if [ "$current_module" = "$SERVER_AXC2_MODULE" ] && [ "$current_version" = "$SERVER_AXC2_VERSION" ]; then
        info_msg "go.mod already up-to-date"
        return
    fi

    step_msg "Syncing go.mod to: $SERVER_AXC2_MODULE@$SERVER_AXC2_VERSION (go $go_directive)"

    if [ -n "$current_module" ] && [ "$current_module" != "$SERVER_AXC2_MODULE" ]; then
        info_msg "Import path change: $current_module -> $SERVER_AXC2_MODULE"
        find "$SCRIPT_DIR" -name '*.go' -exec sed -i "s|\"$current_module\"|\"$SERVER_AXC2_MODULE\"|g" {} \;
        info_msg "Patched import paths in .go files"
    fi

    local module_name
    module_name=$(grep '^module ' "$SCRIPT_DIR/go.mod" | awk '{print $2}')
    cat > "$SCRIPT_DIR/go.mod" <<GOMOD
module $module_name

go $go_directive

require $SERVER_AXC2_MODULE $SERVER_AXC2_VERSION
GOMOD

    (cd "$SCRIPT_DIR" && $GO_BIN get "$SERVER_AXC2_MODULE@$SERVER_AXC2_VERSION" 2>/dev/null)
    (cd "$SCRIPT_DIR" && $GO_BIN mod tidy 2>/dev/null)

    info_msg "go.mod synced"
}

## ========= [ build + deploy ] =========

build_deploy() {
    mkdir -p "$DEPLOY_DIR" || error_exit "Failed to create $DEPLOY_DIR"

    step_msg "Building service_filehost plugin..."
    cd "$SCRIPT_DIR"
    local go_env="CGO_ENABLED=1"
    if [ -n "$GOEXPERIMENT" ]; then
        go_env="GOEXPERIMENT=$GOEXPERIMENT $go_env"
    fi
    eval "$go_env $GO_BIN build -buildmode=plugin \
        -ldflags=\"-s -w\" -o \"$DEPLOY_DIR/service_filehost.so\" ." \
        || error_exit "Failed to build FileHost plugin"

    cp config.yaml ax_config.axs "$DEPLOY_DIR/"
    info_msg "FileHost deployed to $DEPLOY_DIR/"
}

## ========= [ profile.yaml registration ] =========

add_to_profile() {
    local yaml="$SERVER_DIR/profile.yaml"
    if [ ! -f "$yaml" ]; then
        warning_msg "profile.yaml not found - skipping auto-registration"
        return
    fi

    local entry="extenders/file_host/config.yaml"
    if ! grep -qF "$entry" "$yaml"; then
        sed -i "/^  extenders:/a\\    - \"$entry\"" "$yaml"
        info_msg "Registered $entry in profile.yaml"
    else
        info_msg "FileHost already registered in profile.yaml"
    fi
}

## ========= [ summary ] =========

print_summary() {
    echo ""
    info_msg "Done!"
    echo "================================================================"
    echo "  Server:       $SERVER_DIR"
    echo "  GOEXPERIMENT: ${GOEXPERIMENT:-n/a}"
    echo "  Go (local):   $($GO_BIN version 2>/dev/null | grep -oP 'go\d+\.\d+\.\d+')"
    echo "  Go (server):  ${SERVER_GO_VERSION:-n/a}"
    echo "  axc2 module:  ${SERVER_AXC2_MODULE:-n/a}@${SERVER_AXC2_VERSION:-n/a}"
    echo ""
    echo "  Deployed:"
    [ -f "$DEPLOY_DIR/service_filehost.so" ] && echo "    - file_host (service_filehost.so)"
    echo ""
    echo "  Restart adaptixserver to load the plugin."
    echo "  'Site Management' menu will appear in the main menu bar."
    echo "================================================================"
}

## ========= [ main ] =========

find_go
detect_goexperiment
detect_go_version
sync_go_modules
build_deploy
add_to_profile
print_summary
