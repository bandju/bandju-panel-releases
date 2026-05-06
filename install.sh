#!/usr/bin/env bash
set -euo pipefail

# Public production-only installer for bandju-panel.
# Usage:
#   Install:  bash install.sh
#   Update:   bash install.sh --update
#   Rollback: bash install.sh --rollback
#   Remove:   bash install.sh --remove

REMOTE_IMAGE="${BANDJU_REMOTE_IMAGE:-ghcr.io/bandju/bandju-panel:stable}"
PREVIOUS_IMAGE="bandju-panel:previous"
CONTAINER="bandju-panel"
DATA_DIR="/opt/bandju-panel/data"
RUNTIME_META="${DATA_DIR}/panel-runtime.env"
LISTEN="127.0.0.1:7777"
PANEL_BUILD_REF="${BANDJU_BUILD_REF:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; }
step()  { echo -e "\n${GREEN}▸${NC} $*"; }

check_supported_os() {
    local os_id=""
    local os_version=""
    local os_pretty="unknown Linux"

    if [ -r /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        os_version="${VERSION_ID:-}"
        os_pretty="${PRETTY_NAME:-${NAME:-Linux}}"
    fi

    case "${os_id}:${os_version}" in
        ubuntu:22.04|ubuntu:24.04)
            return 0
            ;;
    esac

    error "The VPS OS is not verified for bandju panel: ${os_pretty}."
    echo "  Supported OS versions: Ubuntu 22.04 LTS and Ubuntu 24.04 LTS."
    echo "  Debian 13 and other OS versions are not verified and may not work."
    exit 1
}

current_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

load_runtime_meta() {
    CURRENT_VERSION=""
    CURRENT_BUILD_REF_META=""
    CURRENT_UPDATED_AT=""
    PREVIOUS_VERSION_META=""
    PREVIOUS_BUILD_REF_META=""
    PREVIOUS_UPDATED_AT=""
    ROLLBACK_AVAILABLE_META="0"

    if [ ! -f "${RUNTIME_META}" ]; then
        return 0
    fi

    while IFS='=' read -r key value; do
        case "$key" in
            CURRENT_VERSION) CURRENT_VERSION="$value" ;;
            CURRENT_BUILD_REF) CURRENT_BUILD_REF_META="$value" ;;
            CURRENT_UPDATED_AT) CURRENT_UPDATED_AT="$value" ;;
            PREVIOUS_VERSION) PREVIOUS_VERSION_META="$value" ;;
            PREVIOUS_BUILD_REF) PREVIOUS_BUILD_REF_META="$value" ;;
            PREVIOUS_UPDATED_AT) PREVIOUS_UPDATED_AT="$value" ;;
            ROLLBACK_AVAILABLE) ROLLBACK_AVAILABLE_META="$value" ;;
        esac
    done < "${RUNTIME_META}"
}

write_runtime_meta() {
    local current_version="${1:-}"
    local current_build_ref="${2:-}"
    local current_updated_at="${3:-}"
    local previous_version="${4:-}"
    local previous_build_ref="${5:-}"
    local previous_updated_at="${6:-}"
    local rollback_available="${7:-0}"

    mkdir -p "${DATA_DIR}"
    cat > "${RUNTIME_META}" <<EOF
CURRENT_VERSION=${current_version}
CURRENT_BUILD_REF=${current_build_ref}
CURRENT_UPDATED_AT=${current_updated_at}
PREVIOUS_VERSION=${previous_version}
PREVIOUS_BUILD_REF=${previous_build_ref}
PREVIOUS_UPDATED_AT=${previous_updated_at}
ROLLBACK_AVAILABLE=${rollback_available}
EOF
}

clear_runtime_meta() {
    rm -f "${RUNTIME_META}"
}

fetch_local_url() {
    local url="$1"

    if command -v curl &>/dev/null; then
        curl -fsS "$url"
        return
    fi

    if command -v wget &>/dev/null; then
        wget -qO- "$url"
        return
    fi

    if command -v python3 &>/dev/null; then
        python3 - "$url" <<'PY'
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=5) as response:
    sys.stdout.write(response.read().decode())
PY
        return
    fi

    return 127
}

panel_api_field() {
    local field="$1"
    local json

    json=$(fetch_local_url "http://${LISTEN}/api/version" 2>/dev/null || true)
    if [ -z "$json" ]; then
        return 1
    fi

    printf '%s' "$json" | python3 -c '
import json
import sys

field = sys.argv[1]
payload = json.load(sys.stdin).get("data", {})
value = payload.get(field) or ""
if isinstance(value, (dict, list)):
    print("")
else:
    print(str(value))
' "$field"
}

tag_current_image_as_previous() {
    local current_image_id
    current_image_id=$(docker inspect --format '{{.Image}}' "${CONTAINER}" 2>/dev/null || true)
    if [ -z "${current_image_id}" ]; then
        return 1
    fi
    docker tag "${current_image_id}" "${PREVIOUS_IMAGE}" >/dev/null
}

start_container_with_image() {
    local img="$1"

    docker run -d \
        --name "${CONTAINER}" \
        --restart unless-stopped \
        -p "${LISTEN}:7777" \
        -v /var/run/docker.sock:/var/run/docker.sock:ro \
        -v /:/host:ro \
        -v "${DATA_DIR}:/app/data" \
        -e BANDJU_DATA_DIR=/app/data \
        -e BANDJU_BUILD_REF="${PANEL_BUILD_REF}" \
        "${img}" >/dev/null
}

capture_current_panel_meta() {
    load_runtime_meta

    local version build_ref updated_at
    version=$(panel_api_field "panel" 2>/dev/null || true)
    build_ref=$(panel_api_field "panel_build_ref" 2>/dev/null || true)
    updated_at="${CURRENT_UPDATED_AT:-}"

    if [ -z "${version}" ]; then
        version="${CURRENT_VERSION:-}"
    fi
    if [ -z "${build_ref}" ]; then
        build_ref="${CURRENT_BUILD_REF_META:-}"
    fi
    if [ -z "${updated_at}" ]; then
        updated_at="$(current_timestamp)"
    fi

    printf '%s|%s|%s\n' "${version}" "${build_ref}" "${updated_at}"
}

write_runtime_meta_from_running_panel() {
    local previous_version="${1:-}"
    local previous_build_ref="${2:-}"
    local previous_updated_at="${3:-}"
    local rollback_available="${4:-0}"

    local current_version current_build_ref current_updated_at
    current_version=$(panel_api_field "panel" 2>/dev/null || true)
    current_build_ref=$(panel_api_field "panel_build_ref" 2>/dev/null || true)
    current_updated_at="$(current_timestamp)"

    if [ -z "${current_version}" ]; then
        current_version="?"
    fi

    if [ "${rollback_available}" != "1" ]; then
        previous_version=""
        previous_build_ref=""
        previous_updated_at=""
    fi

    write_runtime_meta \
        "${current_version}" \
        "${current_build_ref}" \
        "${current_updated_at}" \
        "${previous_version}" \
        "${previous_build_ref}" \
        "${previous_updated_at}" \
        "${rollback_available}"
}

download_to_stdout() {
    local url="$1"

    if command -v curl &>/dev/null; then
        curl -fsSL "$url"
        return
    fi

    if command -v wget &>/dev/null; then
        wget -qO- "$url"
        return
    fi

    return 127
}

install_docker() {
    step "Docker not found. Installing..."

    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        warn "curl or wget not found on the VPS. Trying to install curl..."
        if command -v apt-get &>/dev/null; then
            apt-get update >/dev/null && apt-get install -y curl >/dev/null
        fi
    fi

    if ! download_to_stdout "https://get.docker.com" | sh; then
        error "Docker installation failed."
        echo "  Install Docker manually if needed: https://docs.docker.com/engine/install/"
        exit 1
    fi
    systemctl enable docker &>/dev/null || true
    systemctl start docker &>/dev/null || true
    info "Docker installed"
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        install_docker
    fi

    if ! docker info &>/dev/null; then
        error "Docker daemon is not running."
        echo "  Try: systemctl start docker"
        exit 1
    fi
}

pull_release_image() {
    step "Pulling ${REMOTE_IMAGE}..."
    if ! docker pull "${REMOTE_IMAGE}"; then
        error "Unable to pull ${REMOTE_IMAGE}"
        exit 1
    fi
}

wait_healthy() {
    step "Waiting for panel to start..."
    for _ in $(seq 1 15); do
        if docker exec "${CONTAINER}" curl -fsS http://127.0.0.1:7777/api/version &>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

do_install() {
    check_supported_os

    step "Checking Docker..."
    check_docker

    step "Creating data directory..."
    mkdir -p "${DATA_DIR}/logs"
    info "Data: ${DATA_DIR}"

    pull_release_image
    docker image rm -f "${PREVIOUS_IMAGE}" >/dev/null 2>&1 || true

    if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
        step "Removing previous container..."
        docker rm -f "${CONTAINER}" >/dev/null
    fi

    step "Starting container..."
    start_container_with_image "${REMOTE_IMAGE}"

    if wait_healthy; then
        write_runtime_meta_from_running_panel "" "" "" "0"
        echo ""
        info "bandju-panel installed and running"
        info "Address: http://127.0.0.1:7777 (reachable through SSH tunnel only)"
        info "Data: ${DATA_DIR}"
    else
        warn "Container is running, but the panel is not responding yet."
        warn "Check: docker logs ${CONTAINER}"
    fi
}

do_update() {
    check_supported_os

    step "Checking Docker..."
    check_docker

    if ! docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
        error "Container ${CONTAINER} not found. Run install first."
        exit 1
    fi

    local rollback_version rollback_build_ref rollback_updated_at
    IFS='|' read -r rollback_version rollback_build_ref rollback_updated_at <<<"$(capture_current_panel_meta)"

    if ! tag_current_image_as_previous; then
        error "Unable to prepare the current build for rollback."
        exit 1
    fi

    pull_release_image

    step "Restarting container..."
    docker rm -f "${CONTAINER}" >/dev/null
    start_container_with_image "${REMOTE_IMAGE}"

    if wait_healthy; then
        write_runtime_meta_from_running_panel "${rollback_version}" "${rollback_build_ref}" "${rollback_updated_at}" "1"
        local version build_ref
        version=$(panel_api_field "panel" 2>/dev/null || echo "?")
        build_ref=$(panel_api_field "panel_build_ref" 2>/dev/null || true)
        if [ -n "${build_ref}" ]; then
            info "bandju-panel updated to ${version} · ${build_ref}"
        else
            info "bandju-panel updated to ${version}"
        fi
    else
        warn "New build did not come up. Rolling back automatically..."
        docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
        start_container_with_image "${PREVIOUS_IMAGE}" >/dev/null 2>&1 || true
        if wait_healthy; then
            write_runtime_meta \
                "${rollback_version}" \
                "${rollback_build_ref}" \
                "$(current_timestamp)" \
                "" \
                "" \
                "" \
                "0"
            error "New build failed. Previous version restored automatically."
        else
            error "New build failed, and automatic rollback failed too."
        fi
        exit 1
    fi
}

do_rollback() {
    step "Checking Docker..."
    check_docker

    if ! docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
        error "Container ${CONTAINER} not found. Nothing to roll back."
        exit 1
    fi

    if ! docker image inspect "${PREVIOUS_IMAGE}" >/dev/null 2>&1; then
        error "Previous rollback build not found."
        exit 1
    fi

    load_runtime_meta

    local current_version current_build_ref current_updated_at
    IFS='|' read -r current_version current_build_ref current_updated_at <<<"$(capture_current_panel_meta)"

    local target_version target_build_ref target_updated_at
    target_version="${PREVIOUS_VERSION_META:-}"
    target_build_ref="${PREVIOUS_BUILD_REF_META:-}"
    target_updated_at="${PREVIOUS_UPDATED_AT:-}"

    local rollback_temp_image="bandju-panel:rollback-temp"
    local current_image_id
    current_image_id=$(docker inspect --format '{{.Image}}' "${CONTAINER}" 2>/dev/null || true)
    if [ -z "${current_image_id}" ]; then
        error "Unable to capture the current build for a safe rollback."
        exit 1
    fi

    docker tag "${current_image_id}" "${rollback_temp_image}" >/dev/null

    step "Rolling back to previous build..."
    docker rm -f "${CONTAINER}" >/dev/null
    start_container_with_image "${PREVIOUS_IMAGE}"

    if wait_healthy; then
        docker tag "${rollback_temp_image}" "${PREVIOUS_IMAGE}" >/dev/null
        docker image rm -f "${rollback_temp_image}" >/dev/null 2>&1 || true
        write_runtime_meta \
            "${target_version}" \
            "${target_build_ref}" \
            "$(current_timestamp)" \
            "${current_version}" \
            "${current_build_ref}" \
            "${current_updated_at}" \
            "1"
        local version build_ref
        version=$(panel_api_field "panel" 2>/dev/null || echo "?")
        build_ref=$(panel_api_field "panel_build_ref" 2>/dev/null || true)
        if [ -n "${build_ref}" ]; then
            info "Rollback complete: ${version} · ${build_ref}"
        else
            info "Rollback complete: ${version}"
        fi
        return 0
    fi

    warn "Previous build failed. Restoring current version..."
    docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true
    if start_container_with_image "${rollback_temp_image}" >/dev/null 2>&1 && wait_healthy; then
        docker image rm -f "${rollback_temp_image}" >/dev/null 2>&1 || true
        write_runtime_meta \
            "${current_version}" \
            "${current_build_ref}" \
            "${current_updated_at}" \
            "${target_version}" \
            "${target_build_ref}" \
            "${target_updated_at}" \
            "1"
        error "Rollback failed. Current version restored."
    else
        error "Rollback failed, and current version could not be restored automatically."
    fi
    exit 1
}

do_remove() {
    step "Removing bandju-panel..."

    if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
        docker rm -f "${CONTAINER}" >/dev/null
        info "Container removed"
    else
        warn "Container not found"
    fi

    docker image rm -f "${PREVIOUS_IMAGE}" >/dev/null 2>&1 || true
    clear_runtime_meta

    echo ""
    warn "Panel data remains in ${DATA_DIR}"
    warn "To remove it completely: rm -rf ${DATA_DIR}"
}

case "${1:-}" in
    --update)
        do_update
        ;;
    --rollback)
        do_rollback
        ;;
    --remove)
        do_remove
        ;;
    --help|-h)
        echo "bandju-panel public installer"
        echo ""
        echo "Usage:"
        echo "  bash install.sh            Install from stable GHCR image"
        echo "  bash install.sh --update   Update from release image"
        echo "  bash install.sh --rollback Roll back to previous build"
        echo "  bash install.sh --remove   Remove panel container"
        echo ""
        ;;
    "")
        do_install
        ;;
    *)
        error "Unknown argument: $1"
        echo "  bash install.sh --help"
        exit 1
        ;;
esac
