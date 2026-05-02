#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
#  onsyuri-k3s.sh  –  setup & management helper
#  Platforms: WSL2 (Windows), Linux (Raspberry Pi / native), macOS
#
#  Usage:
#    ./onsyuri-k3s.sh install [-i ROOT_PATH] [--game GAMENAME]    # install k3s/k3d + deploy everything
#    ./onsyuri-k3s.sh deploy [-i ROOT_PATH] [--game GAMENAME]     # (re)apply manifests only
#    ./onsyuri-k3s.sh status                    # show pod / service status
#    ./onsyuri-k3s.sh restart                   # restart the pod
#    ./onsyuri-k3s.sh logs                      # tail nginx logs
#    ./onsyuri-k3s.sh clean                     # delete deployment, PVC, PV
#    ./onsyuri-k3s.sh debug                     # open shell into pod
#    ./onsyuri-k3s.sh uninstall                 # remove k3s/k3d completely
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[onsyuri]${NC} $*"; }
warn()  { echo -e "${YELLOW}[onsyuri]${NC} $*"; }
error() { echo -e "${RED}[onsyuri]${NC} $*" >&2; exit 1; }

CMD="${1:-help}"
shift || true

ROOT_PATH_OVERRIDE=""
GAME_TITLE_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--root-path)
            if [[ $# -lt 2 ]]; then
                error "Missing value for $1"
            fi
            ROOT_PATH_OVERRIDE="$2"
            shift 2
            ;;
        --game)
            if [[ $# -lt 2 ]]; then
                error "Missing value for $1"
            fi
            GAME_TITLE_OVERRIDE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        -* )
            error "Unknown option: $1"
            ;;
        *)
            error "Unknown argument: $1"
            ;;
    esac
done

if [[ -n "$ROOT_PATH_OVERRIDE" && "$CMD" != "install" && "$CMD" != "deploy" ]]; then
    error "The -i option is only valid with install or deploy."
fi
if [[ -n "$GAME_TITLE_OVERRIDE" && "$CMD" != "install" && "$CMD" != "deploy" ]]; then
    error "The --game option is only valid with install or deploy."
fi

# ── Platform detection ─────────────────────────────────────────────────────
ROOT_PATH=""
GAME_SUBDIR=""
PLATFORM=""

detect_platform() {
    case "$(uname -s)" in
        Linux)
            if grep -qi microsoft /proc/version 2>/dev/null; then
                PLATFORM="wsl2"
            elif grep -qi "raspberry" /proc/cpuinfo 2>/dev/null \
                 || grep -qi "bcm" /proc/cpuinfo 2>/dev/null; then
                PLATFORM="rpi"
            else
                PLATFORM="linux"
            fi
            ;;
        Darwin) PLATFORM="macos" ;;
        *)      PLATFORM="unknown" ;;
    esac
}

# ── Configuration (platform-aware) ────────────────────────────────────────────
get_default_root_path() {
    case "$PLATFORM" in
    wsl2)   ROOT_PATH="$(wslpath "$(powershell.exe -c "Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -Name '{4C5C32FF-BB9D-43b0-B5B4-2D72E54EAAA4}'" | tr -d '\r')")/onsyuri_web" ;;
    macos)  ROOT_PATH="$HOME/Games/onsyuri_web" ;;
    rpi)    ROOT_PATH="/home/pi/onsyuri_web" ;;
    *)      ROOT_PATH="/opt/onsyuri_web" ;;
    esac
}

get_game_subdir() {
    if [[ -n "$GAME_TITLE_OVERRIDE" ]]; then
        GAME_SUBDIR="$GAME_TITLE_OVERRIDE"
        return
    fi

    shopt -s nullglob
    local dirs=("$ROOT_PATH"/*/)
    shopt -u nullglob

    if [[ ${#dirs[@]} -eq 0 ]]; then
        error "No game subdirectory found under $ROOT_PATH. Set it with --game GAMENAME."
    fi

    GAME_SUBDIR="$(basename "${dirs[0]}")"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/k3s-manifests.yaml"
NAMESPACE="onsyuri"

# ── LAN IP (platform-aware) ────────────────────────────────────────────────
get_lan_ip() {
    case "$PLATFORM" in
        macos)  ipconfig getifaddr en0 2>/dev/null \
                    || ipconfig getifaddr en1 2>/dev/null \
                    || echo "127.0.0.1" ;;
        # uncomment if `netsh` localhost forwarding of WSL2 is set up
        # wsl2)
        #     powershell.exe -Command "(Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias 'Ethernet').IPAddress" 2>/dev/null;;
        *)      hostname -I 2>/dev/null | awk '{print $1}' \
                    || echo "127.0.0.1" ;;
    esac
}

# ── k3s install (Linux / WSL2 / RPi) ──────────────────────────────────────
install_k3s_linux() {
    if command -v k3s &>/dev/null; then
        info "k3s already installed ($(k3s --version | head -1))"
    else
        info "Installing k3s..."
        # On RPi (arm64/armv7) the same script works; k3s ships multi-arch binaries
        curl -sfL https://get.k3s.io | sh -
        mkdir -p ~/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
        sudo chown "$USER":"$USER" ~/.kube/config
        export KUBECONFIG=~/.kube/config
        info "Waiting for node to be ready..."
        kubectl wait node --all --for=condition=Ready --timeout=120s
    fi
}

# NOT TESTED ON MACOS
# ── k3d install (macOS — k3s runs inside Docker via k3d) ──────────────────
# k3d creates a k3s cluster inside Docker Desktop / OrbStack on macOS.
# Prerequisite: Docker Desktop or OrbStack must be running.
install_k3d_macos() {
    if ! command -v docker &>/dev/null; then
        error "Docker not found. Install Docker Desktop or OrbStack first:\n  https://orbstack.dev  (lighter)"
    fi
    if ! command -v k3d &>/dev/null; then
        info "Installing k3d via Homebrew..."
        brew install k3d || error "Homebrew not found — install it from https://brew.sh"
    fi
    if k3d cluster list 2>/dev/null | grep -q "onsyuri"; then
        info "k3d cluster 'onsyuri' already exists"
    else
        info "Creating k3d cluster 'onsyuri'..."
        # Port-map 80 on the host → port 80 inside the cluster (Traefik)
        # Mount ROOT_PATH into every agent node so hostPath PVs resolve
        k3d cluster create onsyuri \
            --port "80:80@loadbalancer" \
            --volume "${ROOT_PATH}:${ROOT_PATH}@server:0" \
            --volume "${SCRIPT_DIR}:${SCRIPT_DIR}@server:0"
    fi
    k3d kubeconfig merge onsyuri --kubeconfig-merge-default
    kubectl config use-context k3d-onsyuri
}

install_k3s() {
    case "$PLATFORM" in
        macos)  install_k3d_macos ;;
        *)      install_k3s_linux ;;
    esac
}

uninstall_k3s() {
    warn "This will remove k3s/k3d and all workloads. Press Ctrl-C to cancel..."
    sleep 5
    case "$PLATFORM" in
        macos)
            k3d cluster delete onsyuri 2>/dev/null || true
            info "k3d cluster removed."
            ;;
        wsl2)
            # k3s-uninstall.sh calls k3s-killall.sh which does kill -9 on all
            # k3s child processes. On WSL2 this tree includes the init process
            # that holds the fd-transport (trans=fd) open for 9P DrvFs mounts
            # like /mnt/d. Once that fd is closed the mount is a permanent
            # zombie — not recoverable without wsl --shutdown.
            # Fix: bypass k3s-uninstall.sh entirely. Stop k3s cleanly via
            # systemctl (graceful, no killtree), then do the file cleanup
            # ourselves. This avoids touching the WSL2 init process tree.
            info "Stopping k3s service gracefully (WSL2-safe)..."
            sudo systemctl stop k3s 2>/dev/null || true
            sudo systemctl disable k3s 2>/dev/null || true
            sudo systemctl reset-failed k3s 2>/dev/null || true
            sudo systemctl daemon-reload 2>/dev/null || true

            info "Unmounting k3s-managed paths..."
            # Only unmount paths k3s owns — never touch /mnt/* (DrvFs)
            for prefix in /run/k3s /var/lib/rancher/k3s /var/lib/kubelet; do
                while IFS= read -r mp; do
                    sudo umount -l "$mp" 2>/dev/null || true
                done < <(awk '{print $2}' /proc/self/mounts | grep "^${prefix}" | sort -r)
            done

            info "Removing k3s files..."
            sudo rm -f /usr/local/bin/k3s
            sudo rm -f /usr/local/bin/kubectl /usr/local/bin/crictl /usr/local/bin/ctr
            sudo rm -f /usr/local/bin/k3s-uninstall.sh /usr/local/bin/k3s-killall.sh
            sudo rm -f /etc/systemd/system/k3s.service /etc/systemd/system/k3s.service.env
            sudo rm -rf /etc/rancher/k3s /run/k3s
            sudo rm -rf /var/lib/rancher/k3s /var/lib/kubelet
            sudo rm -rf /var/lib/cni /etc/cni
            sudo ip link delete flannel.1 2>/dev/null || true
            sudo ip link delete cni0 2>/dev/null || true

            info "k3s uninstalled. Windows drives untouched."
            ;;
        *)
            /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true
            info "k3s uninstalled."
            ;;
    esac
}

# ── The rest is identical across all platforms ─────────────────────────────
validate_paths() {
    [[ -d "$ROOT_PATH" ]]              || error "Root path not found: $ROOT_PATH"
    [[ -d "$ROOT_PATH/$GAME_SUBDIR" ]] || error "Game subfolder not found: $ROOT_PATH/$GAME_SUBDIR"
    [[ -f "$ROOT_PATH/onsyuri_index.py" ]] || \
        error "onsyuri_index.py not found in $ROOT_PATH - clone the repo first"
    [[ -f "$ROOT_PATH/onsyuri.html" ]] || \
        warn "onsyuri.html not found in $ROOT_PATH – did you copy the web build?"
    [[ -f "$SCRIPT_DIR/nginx.conf" ]] || \
        error "nginx.conf not found in $SCRIPT_DIR"
}

patch_manifest() {
    export ROOT_PATH GAME_SUBDIR SCRIPT_DIR
    RENDERED=$(mktemp /tmp/onsyuri-manifest-XXXX.yaml)
    envsubst '${ROOT_PATH} ${GAME_SUBDIR} ${SCRIPT_DIR}' < "$MANIFEST" > "$RENDERED"
    info "Platform    : ${PLATFORM}" >&2
    info "Root path   : ${ROOT_PATH}" >&2
    info "Game subdir : ${GAME_SUBDIR}" >&2
    info "Script dir  : ${SCRIPT_DIR}" >&2
    info "RENDERED    : $RENDERED" >&2
    echo "$RENDERED"
}

deploy() {
    export KUBECONFIG=~/.kube/config
    RENDERED=$(patch_manifest)
    kubectl apply -f "$RENDERED"
    rm -f "$RENDERED"

    info "Waiting for pod to be created (init container may pull images)..."
    for i in $(seq 1 60); do
        COUNT=$(kubectl get pods -n "$NAMESPACE" -l app=onsyuri \
                    --no-headers 2>/dev/null | wc -l)
        [[ "$COUNT" -gt 0 ]] && break
        sleep 2
    done

    info "Pod created, waiting for Ready..."
    kubectl wait pod -n "$NAMESPACE" -l app=onsyuri \
        --for=condition=Ready --timeout=180s || {
        warn "Pod not ready yet — showing current state:"
        kubectl get pods -n "$NAMESPACE" -o wide
        warn "Init container logs: kubectl logs -n $NAMESPACE -l app=onsyuri -c index-generator"
    }
    echo ""
}

status() {
    export KUBECONFIG=~/.kube/config
    LAN_IP=$(get_lan_ip)
    echo ""
    info "── Platform : ${PLATFORM} ───────────────────────────────"
    info "── Pods ────────────────────────────────────────────────"
    kubectl get pods -n "$NAMESPACE" -o wide
    echo ""
    info "── Service / Ingress ────────────────────────────────────"
    kubectl get svc,ingress -n "$NAMESPACE"
    echo ""
    info "── Access ───────────────────────────────────────────────"
    echo -e "  LAN   : ${GREEN}http://${LAN_IP}/${NC}"
    echo -e "  Local : ${GREEN}http://localhost/${NC}"
    echo ""
}

restart() {
    export KUBECONFIG=~/.kube/config
    info "Restarting pod (reruns init container → regenerates index.json)..."
    kubectl rollout restart deployment/onsyuri -n "$NAMESPACE"
    kubectl rollout status deployment/onsyuri -n "$NAMESPACE"
}

logs() {
    export KUBECONFIG=~/.kube/config
    kubectl logs -n "$NAMESPACE" -l app=onsyuri -c nginx --follow
}

clean() {
    export KUBECONFIG=~/.kube/config
    warn "Deleting deployment, PVC, and PV..."
    kubectl delete deployment/onsyuri -n "$NAMESPACE" --ignore-not-found=true
    kubectl delete pvc --all -n "$NAMESPACE" --ignore-not-found=true
    kubectl delete pv --all --ignore-not-found=true
    info "Cleaned up resources."
}

debug() {
    export KUBECONFIG=~/.kube/config
    POD=$(kubectl get pods -n "$NAMESPACE" -l app=onsyuri \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -z "$POD" ]] && error "No pod found. Make sure deployment is running."
    info "Opening shell into pod: $POD"
    kubectl exec -it "$POD" -n "$NAMESPACE" -- sh
}

# ── Entry point ────────────────────────────────────────────────────────────
if [[ -n "$ROOT_PATH_OVERRIDE" && "$CMD" != "install" && "$CMD" != "deploy" ]]; then
    error "The -i option is only valid with install or deploy."
fi
case "$CMD" in
    install)
        detect_platform
        [[ -n "$ROOT_PATH_OVERRIDE" ]] && ROOT_PATH="$ROOT_PATH_OVERRIDE" || get_default_root_path
        get_game_subdir
        validate_paths; install_k3s; deploy; status
        ;;
    deploy)
        detect_platform
        [[ -n "$ROOT_PATH_OVERRIDE" ]] && ROOT_PATH="$ROOT_PATH_OVERRIDE" || get_default_root_path
        get_game_subdir
        validate_paths; clean; deploy; status
        ;;
    status)    detect_platform; status ;;
    restart)   restart ;;
    logs)      logs ;;
    clean)     clean ;;
    debug)     debug ;;
    uninstall) detect_platform; uninstall_k3s ;;
    *)
        echo "Usage: $0 {install|deploy|status|restart|logs|clean|debug|uninstall}"
        exit 1
        ;;
esac