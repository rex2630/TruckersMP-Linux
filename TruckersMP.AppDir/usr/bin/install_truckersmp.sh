#!/usr/bin/env bash

#===============================================================================
# TruckersMP Installer for Linux
# Version: 1.0.0
# Original-Author: rs189
# Edited by: rex2630
# License: MIT
#===============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="1.0.0"
readonly LOG_FILE="/tmp/truckersmp_installer.log"
readonly TLM_DOWNLOAD_URL="https://github.com/3ventic/tlm/releases/latest/download/tlm-x86_64-unknown-linux-gnu"
readonly UMU_PROTON_API_URL="https://api.github.com/repos/Open-Wine-Components/umu-proton/releases/latest"
readonly APP_ID_ETS2="227300"
readonly APP_ID_ATS="270880"

TMP_DIR="$(mktemp -d -t truckersmp-installer-XXXXXX)"
TLM_BIN="$TMP_DIR/tlm"

STEAM_COMPAT_PATH=""
STEAM_VARIANT=""
SELECTED_GAME=""
SELECTED_APP_ID=""
SELECTED_LIBRARY=""
SELECTED_MANIFEST=""

log() {
    local level="$1"
    shift
    local msg="$*"
    echo "[$(date +'%F %T')] [$level] $msg" | tee -a "$LOG_FILE"
}

emit_info() {
    echo "INFO:$*"
    log "INFO" "$*"
}

emit_warn() {
    echo "WARN:$*"
    log "WARN" "$*"
}

emit_error() {
    echo "ERROR:$*"
    log "ERROR" "$*"
}

emit_done() {
    echo "DONE:$*"
    log "DONE" "$*"
}

cleanup() {
    log "INFO" "Cleaning up temporary files"
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

progress() {
    echo "PROGRESS:$1"
}

require_non_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        emit_error "This installer must not be run as root or via sudo."
        exit 1
    fi
}

check_dependencies() {
    local deps=(curl chmod mkdir awk grep find sed tr tar)
    local dep

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            emit_error "Missing required dependency: $dep"
            exit 1
        fi
    done
}

find_steam_compat_path() {
    local candidates=(
        "$HOME/.steam/root/compatibilitytools.d"
        "$HOME/.local/share/Steam/compatibilitytools.d"
        "$HOME/.steam/steam/compatibilitytools.d"
        "$HOME/.var/app/com.valvesoftware.Steam/.steam/root/compatibilitytools.d"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d"
        "$HOME/snap/steam/common/.steam/root/compatibilitytools.d"
    )

    local p
    for p in "${candidates[@]}"; do
        if [[ -d "$(dirname "$p")" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    return 1
}

detect_steam_variant() {
    case "$STEAM_COMPAT_PATH" in
        *".var/app/com.valvesoftware.Steam"*)
            STEAM_VARIANT="flatpak"
            ;;
        *"/snap/steam/"*)
            STEAM_VARIANT="snap"
            ;;
        *)
            STEAM_VARIANT="native"
            ;;
    esac
}

find_libraryfolders_files() {
    local roots=(
        "$HOME/.local/share/Steam"
        "$HOME/.steam/steam"
        "$HOME/.steam/root"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
        "$HOME/.var/app/com.valvesoftware.Steam/.steam/root"
        "$HOME/snap/steam/common/.local/share/Steam"
        "$HOME/snap/steam/common/.steam/root"
    )

    local root
    for root in "${roots[@]}"; do
        [[ -f "$root/steamapps/libraryfolders.vdf" ]] && printf '%s\n' "$root/steamapps/libraryfolders.vdf"
        [[ -f "$root/config/libraryfolders.vdf" ]] && printf '%s\n' "$root/config/libraryfolders.vdf"
    done
}

find_steam_libraries() {
    local -A seen=()
    local file
    local line_path
    local dir

    while IFS= read -r file; do
        [[ -n "$file" ]] || continue

        dir="$(dirname "$(dirname "$file")")"
        if [[ -d "$dir/steamapps" && -z "${seen[$dir]:-}" ]]; then
            seen["$dir"]=1
            printf '%s\n' "$dir"
        fi

        while IFS= read -r line_path; do
            [[ -n "$line_path" ]] || continue
            if [[ -d "$line_path/steamapps" && -z "${seen[$line_path]:-}" ]]; then
                seen["$line_path"]=1
                printf '%s\n' "$line_path"
            fi
        done < <(awk -F'"' '
            $2 ~ /^[0-9]+$/ && $4 ~ /^\// { print $4 }
            $2 == "path" && $4 ~ /^\// { print $4 }
        ' "$file")
    done < <(find_libraryfolders_files)
}

find_installed_game() {
    local app_id game_name
    local library

    while IFS= read -r library; do
        [[ -n "$library" ]] || continue

        for app_id in "$APP_ID_ETS2" "$APP_ID_ATS"; do
            if [[ "$app_id" == "$APP_ID_ETS2" ]]; then
                game_name="ETS2"
            else
                game_name="ATS"
            fi

            if [[ -f "$library/steamapps/appmanifest_${app_id}.acf" ]]; then
                SELECTED_GAME="$game_name"
                SELECTED_APP_ID="$app_id"
                SELECTED_LIBRARY="$library"
                SELECTED_MANIFEST="$library/steamapps/appmanifest_${app_id}.acf"
                return 0
            fi
        done
    done < <(find_steam_libraries)

    return 1
}

have_pkexec() {
    command -v pkexec >/dev/null 2>&1
}

run_root_cmd() {
    local cmd="$1"

    if have_pkexec; then
        pkexec /bin/sh -c "$cmd"
        return $?
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo /bin/sh -c "$cmd"
        return $?
    fi

    return 1
}

try_install_umu() {
    emit_info "umu-run was not found. Attempting automatic installation."

    if command -v pacman >/dev/null 2>&1; then
        emit_info "Detected pacman-based system. Installing umu-launcher."
        run_root_cmd "pacman -Sy --needed --noconfirm umu-launcher" && return 0
    fi

    if command -v dnf >/dev/null 2>&1; then
        emit_info "Detected dnf-based system. Installing umu-launcher."
        run_root_cmd "dnf install -y umu-launcher" && return 0
    fi

    if command -v zypper >/dev/null 2>&1; then
        emit_info "Detected zypper-based system. Installing umu-launcher."
        run_root_cmd "zypper --non-interactive install umu-launcher" && return 0
    fi

    if command -v apt-get >/dev/null 2>&1; then
        emit_info "Detected apt-based system. Installing umu-launcher."
        run_root_cmd "apt-get update && apt-get install -y --install-recommends umu-launcher" && return 0
    fi

    if command -v nix-env >/dev/null 2>&1; then
        emit_info "Detected Nix environment. Installing umu-launcher."
        nix-env -iA nixpkgs.umu-launcher && return 0
    fi

    return 1
}

ensure_umu_run() {
    if command -v umu-run >/dev/null 2>&1; then
        emit_info "umu-run found in PATH."
        return 0
    fi

    if try_install_umu; then
        hash -r
        if command -v umu-run >/dev/null 2>&1; then
            emit_info "umu-run was installed successfully."
            return 0
        fi
    fi

    emit_error "umu-run is required but could not be installed automatically. Please install umu-launcher manually and run the installer again."
    exit 1
}

list_proton_candidates() {
    local proton_candidates=(
        "$HOME/.local/share/Steam/compatibilitytools.d"
        "$HOME/.steam/root/compatibilitytools.d"
        "$HOME/.steam/steam/compatibilitytools.d"
        "$HOME/.local/share/Steam/steamapps/common"
        "$HOME/.steam/steam/steamapps/common"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d"
        "$HOME/.var/app/com.valvesoftware.Steam/.steam/root/compatibilitytools.d"
        "$HOME/snap/steam/common/.local/share/Steam/compatibilitytools.d"
        "$HOME/snap/steam/common/.steam/root/compatibilitytools.d"
    )

    local base
    for base in "${proton_candidates[@]}"; do
        [[ -d "$base" ]] || continue
        find "$base" -maxdepth 1 -mindepth 1 -type d \
            \( -name 'UMU-Proton*' -o -name 'GE-Proton*' -o -name 'Proton 10*' -o -name 'Proton Experimental' \) \
            2>/dev/null
    done
}

have_compatible_proton() {
    list_proton_candidates | grep -q .
}

install_umu_proton() {
    local compat_dir="$HOME/.local/share/Steam/compatibilitytools.d"
    local archive="$TMP_DIR/umu-proton.tar.gz"
    local download_url

    emit_info "No compatible Proton runtime detected. Attempting to install latest UMU-Proton."
    mkdir -p "$compat_dir"

    download_url="$(
        curl --fail --silent --show-error --location "$UMU_PROTON_API_URL" \
        | grep '"browser_download_url":' \
        | grep -E 'UMU-Proton[^"]*\.tar\.(gz|xz|zst)' \
        | head -n 1 \
        | sed -E 's/.*"([^"]+)".*/\1/'
    )"

    if [[ -z "$download_url" ]]; then
        emit_warn "Could not determine latest UMU-Proton download URL from GitHub API."
        return 1
    fi

    emit_info "Downloading latest UMU-Proton package."
    curl --fail --location --silent --show-error "$download_url" -o "$archive"

    emit_info "Extracting UMU-Proton into $compat_dir"
    case "$download_url" in
        *.tar.gz)
            tar -xzf "$archive" -C "$compat_dir"
            ;;
        *.tar.xz)
            tar -xJf "$archive" -C "$compat_dir"
            ;;
        *.tar.zst)
            if command -v unzstd >/dev/null 2>&1; then
                unzstd -c "$archive" | tar -xf - -C "$compat_dir"
            elif command -v zstd >/dev/null 2>&1; then
                zstd -dc "$archive" | tar -xf - -C "$compat_dir"
            else
                emit_warn "Downloaded a .tar.zst archive but neither unzstd nor zstd is available."
                return 1
            fi
            ;;
        *)
            emit_warn "Unsupported UMU-Proton archive format."
            return 1
            ;;
    esac

    return 0
}

ensure_proton_runtime() {
    if have_compatible_proton; then
        emit_info "Detected at least one compatible Proton runtime."
        return 0
    fi

    if install_umu_proton && have_compatible_proton; then
        emit_info "UMU-Proton was installed successfully."
        return 0
    fi

    emit_warn "No Proton runtime was detected automatically, and UMU-Proton could not be installed."
    emit_warn "Make sure Proton or UMU-Proton is installed in Steam compatibilitytools.d and run the game at least once before using TruckersMP."
    return 0
}

download_tlm() {
    emit_info "Downloading TLM binary"
    curl --fail --location --silent --show-error "$TLM_DOWNLOAD_URL" -o "$TLM_BIN"
    chmod +x "$TLM_BIN"
}

install_tlm() {
    emit_info "Installing TLM into Steam compatibilitytools.d"
    "$TLM_BIN" install-steam-tool --steam-compat-path "$STEAM_COMPAT_PATH"
}

verify_install() {
    local tool_dir="$STEAM_COMPAT_PATH/TLM"

    [[ -d "$tool_dir" ]] || { emit_error "TLM directory was not created: $tool_dir"; exit 1; }
    [[ -f "$tool_dir/compatibilitytool.vdf" ]] || { emit_error "Missing compatibilitytool.vdf"; exit 1; }
    [[ -f "$tool_dir/toolmanifest.vdf" ]] || { emit_error "Missing toolmanifest.vdf"; exit 1; }
    [[ -f "$tool_dir/tlm" ]] || { emit_error "Missing tlm binary in tool directory"; exit 1; }
    [[ -f "$tool_dir/tlm.sh" ]] || { emit_error "Missing tlm.sh launcher script"; exit 1; }

    emit_info "TLM installation verified successfully."
}

print_summary() {
    emit_done "Installation completed successfully."
    emit_done "Steam variant: $STEAM_VARIANT"
    emit_done "Compatibility tools path: $STEAM_COMPAT_PATH"
    emit_done "Detected game: $SELECTED_GAME (AppID $SELECTED_APP_ID)"
    emit_done "Next step: restart Steam."
    emit_done "Then open Properties for $SELECTED_GAME -> Compatibility -> Force the use of a specific Steam Play compatibility tool -> select 'TruckersMP [TLM]'."
    emit_done "Finally, launch the game from Steam."
}

main() {
    : > "$LOG_FILE"

    emit_info "Starting TruckersMP one-click installer v$VERSION"
    progress 5

    require_non_root
    check_dependencies
    progress 15

    STEAM_COMPAT_PATH="$(find_steam_compat_path || true)"
    if [[ -z "$STEAM_COMPAT_PATH" ]]; then
        emit_error "Could not locate Steam compatibilitytools.d path. Please launch Steam at least once first."
        exit 1
    fi

    mkdir -p "$STEAM_COMPAT_PATH"
    detect_steam_variant
    emit_info "Detected Steam variant: $STEAM_VARIANT"
    emit_info "Using compatibility path: $STEAM_COMPAT_PATH"
    progress 25

    if find_installed_game; then
        emit_info "Detected installed game: $SELECTED_GAME"
        emit_info "Using Steam library: $SELECTED_LIBRARY"
    else
        emit_error "Neither ETS2 nor ATS was found in your Steam libraries."
        exit 1
    fi
    progress 35

    ensure_umu_run
    progress 55

    ensure_proton_runtime
    progress 65

    download_tlm
    progress 80

    install_tlm
    progress 95

    verify_install
    progress 100

    print_summary
}

main "$@"
