#!/usr/bin/env bash

#===============================================================================
# TruckersMP Installer for Linux
# Version: 1.1.1
# Author: rs189
# License: MIT
# Description: Installs and configures TruckersMP for Euro Truck Simulator 2 using Wine
#===============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Configuration
readonly VERSION="1.1.1"
readonly REQUIRED_WINE_VERSION="9.15"
readonly APP_ID_ETS2="227300"
readonly LOG_FILE="/tmp/truckersmp_installer.log"
readonly DEFAULT_PROTON_NAME="Proton Experimental"

TMP_DIR="$(mktemp -d -t truckersmp-installer-XXXXXX)"
SETUP_EXE="$TMP_DIR/TruckersMP-Setup.exe"
WINETRICKS_BIN="$TMP_DIR/winetricks"

STEAM_LIBRARY=""
STEAM_ROOT=""
ETS2_DIR=""
WINEPREFIX=""
TRUCKERSMP_PATH=""

PROTON_NAME="${PROTON_NAME:-$DEFAULT_PROTON_NAME}"
PROTON_DIR=""
PROTON_EXEC=""
STEAM_COMPAT_CLIENT_INSTALL_PATH=""
STEAM_COMPAT_DATA_PATH=""

SYSTEM_WINE_BIN=""
WINESERVER=""
WINE64=""
WINE_BIN=""
USE_SYSTEM_WINE_FALLBACK=0

STABLE_TMP_ROOT="$HOME/.local/share/TruckersMP"
STABLE_IPC_BRIDGE="$STABLE_TMP_ROOT/winediscordipcbridge.exe"
STABLE_LAUNCHER_SCRIPT="$HOME/.local/bin/truckersmp-launcher"
STABLE_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/truckersmp-launcher.conf"
APPLICATIONS_DIR="$HOME/.local/share/applications"

log() {
    local level=$1
    shift
    local msg="$*"
    echo "[$(date +'%F %T')] [$level] $msg" | tee -a "$LOG_FILE"
}

emit_info() { echo "INFO:$*"; log "INFO" "$*"; }
emit_warn() { echo "WARN:$*"; log "WARN" "$*"; }
emit_error() { echo "ERROR:$*"; log "ERROR" "$*"; }

cleanup() {
    log "INFO" "Cleaning up"
    if [[ -n "${WINESERVER:-}" && -x "${WINESERVER:-}" ]]; then
        "$WINESERVER" -k || true
    fi
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

find_steam_roots() {
    local roots=(
        "$HOME/.local/share/Steam"
        "$HOME/.steam/steam"
        "$HOME/.steam/root"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"
    )

    local r
    for r in "${roots[@]}"; do
        [[ -d "$r" ]] && printf '%s\n' "$r"
    done
}

find_ets2_library() {
    local root vdf
    local -a libpaths=()
    local -A seen=()

    while IFS= read -r root; do
        libpaths+=("$root")
        for vdf in "$root/steamapps/libraryfolders.vdf" "$root/config/libraryfolders.vdf"; do
            [[ -f "$vdf" ]] || continue
            while IFS= read -r path; do
                [[ -n "$path" ]] && libpaths+=("$path")
            done < <(awk -F'"' '$2 ~ /^[0-9]+$/ && $4 ~ /^\// { print $4 } $2 == "path" && $4 ~ /^\// { print $4 }' "$vdf")
        done
    done < <(find_steam_roots)

    local p
    for p in "${libpaths[@]}"; do
        [[ -n "$p" ]] || continue
        [[ -n "${seen[$p]:-}" ]] && continue
        seen["$p"]=1
        if [[ -f "$p/steamapps/appmanifest_${APP_ID_ETS2}.acf" ]]; then
            printf '%s\n' "$p"
            return 0
        fi
    done

    return 1
}

find_steam_root_for_library() {
    local library="$1"
    local root
    while IFS= read -r root; do
        if [[ "$library" == "$root"* ]]; then
            printf '%s\n' "$root"
            return 0
        fi
    done < <(find_steam_roots)
    return 1
}

find_proton_dir() {
    local -a candidates=(
        "$STEAM_ROOT/steamapps/common/$PROTON_NAME"
        "$HOME/.local/share/Steam/steamapps/common/$PROTON_NAME"
        "$HOME/.steam/steam/steamapps/common/$PROTON_NAME"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/$PROTON_NAME"
        "$STEAM_ROOT/compatibilitytools.d/$PROTON_NAME"
        "$HOME/.local/share/Steam/compatibilitytools.d/$PROTON_NAME"
        "$HOME/.steam/steam/compatibilitytools.d/$PROTON_NAME"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d/$PROTON_NAME"
    )

    local c
    for c in "${candidates[@]}"; do
        [[ -f "$c/proton" ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

autodetect_proton_dir() {
    local -a bases=(
        "$STEAM_ROOT/steamapps/common"
        "$HOME/.local/share/Steam/steamapps/common"
        "$HOME/.steam/steam/steamapps/common"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common"
        "$STEAM_ROOT/compatibilitytools.d"
        "$HOME/.local/share/Steam/compatibilitytools.d"
        "$HOME/.steam/steam/compatibilitytools.d"
        "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/compatibilitytools.d"
    )

    local base candidate
    for base in "${bases[@]}"; do
        [[ -d "$base" ]] || continue
        for candidate in \
            "$base/Proton Experimental" \
            "$base/GE-Proton"* \
            "$base/Proton-CachyOS Latest" \
            "$base/Proton Hotfix" \
            "$base/Proton 10."* \
            "$base/Proton 9."* \
            "$base/UMU-Proton-10.0-4" \
            "$base/UMU-Proton-9.0-3.2"; do
            [[ -f "$candidate/proton" ]] && { printf '%s\n' "$candidate"; return 0; }
        done
    done
    return 1
}

check_dependencies() {
    local deps=(zenity jq wget awk sed grep pgrep pkill cp chmod python3 find sort tail tr mktemp mkdir xdg-user-dir)
    local dep
    for dep in "${deps[@]}"; do
        command -v "$dep" >/dev/null 2>&1 || { emit_error "Required dependency '$dep' is not installed"; exit 1; }
    done
    SYSTEM_WINE_BIN="$(command -v wine || true)"
}

resolve_proton_wine_bin() {
    local proton_bin_dir="$1"
    [[ -x "$proton_bin_dir/wine" ]] && { printf '%s\n' "$proton_bin_dir/wine"; return 0; }
    [[ -x "$proton_bin_dir/wine64" ]] && { printf '%s\n' "$proton_bin_dir/wine64"; return 0; }
    return 1
}

init_wine_backend() {
    local proton_bin_dir=""
    for proton_bin_dir in "$PROTON_DIR/files/bin" "$PROTON_DIR/dist/bin" "$PROTON_DIR/bin"; do
        [[ -d "$proton_bin_dir" ]] || continue
        WINESERVER="$proton_bin_dir/wineserver"
        WINE64="$proton_bin_dir/wine64"
        WINE_BIN="$(resolve_proton_wine_bin "$proton_bin_dir" || true)"
        if [[ -n "$WINE_BIN" && -x "$WINE_BIN" && -x "$WINESERVER" ]]; then
            USE_SYSTEM_WINE_FALLBACK=0
            emit_info "Using Proton Wine for installer: $WINE_BIN"
            return 0
        fi
    done

    if [[ -n "$SYSTEM_WINE_BIN" ]]; then
        WINE_BIN="$SYSTEM_WINE_BIN"
        WINESERVER="$(command -v wineserver || true)"
        WINE64="$(command -v wine64 || true)"
        USE_SYSTEM_WINE_FALLBACK=1
        emit_info "Using system Wine fallback for installer: $WINE_BIN"
        return 0
    fi

    emit_error "No usable Wine backend was found."
    exit 1
}

check_wine_version() {
    local wine_version
    wine_version="$("$WINE_BIN" --version | grep -oE '[0-9]+\.[0-9]+' | head -n 1 || true)"
    wine_version="${wine_version:-0.0}"
    emit_info "Detected Wine version: $wine_version"

    if ! printf '%s\n%s\n' "$REQUIRED_WINE_VERSION" "$wine_version" | sort -V -C; then
        emit_error "Wine version $wine_version is lower than required version $REQUIRED_WINE_VERSION."
        exit 1
    fi
}

ensure_prefix_ready() {
    mkdir -p "$WINEPREFIX"
    emit_info "Initializing Wine prefix"
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" wineboot -u >/dev/null 2>&1 || {
        emit_error "Wine prefix initialization failed."
        exit 1
    }

    [[ -x "${WINESERVER:-}" ]] && "$WINESERVER" -k || true
}

check_appdata() {
    local appdata
    appdata="$(WINEPREFIX="$WINEPREFIX" "$WINE_BIN" cmd /c "echo %AppData%" 2>/dev/null | tr -d '\r' | grep -E '^[A-Z]:\\' | tail -n 1 || true)"
    [[ -n "$appdata" ]] || {
        emit_error "Wine prefix is not usable: %AppData% lookup failed."
        exit 1
    }
    emit_info "Wine AppData path detected: $appdata"
}

install_winetricks_corefonts() {
    if [[ ! -f "$WINETRICKS_BIN" ]]; then
        emit_info "Downloading winetricks"
        wget -O "$WINETRICKS_BIN" "https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks"
        chmod +x "$WINETRICKS_BIN"
    fi

    [[ -x "${WINESERVER:-}" ]] && "$WINESERVER" -k || true

    if ! WINEPREFIX="$WINEPREFIX" WINE="$WINE_BIN" WINESERVER="$WINESERVER" "$WINETRICKS_BIN" --force -q corefonts; then
        emit_warn "winetricks corefonts failed; continuing without corefonts"
    fi

    [[ -x "${WINESERVER:-}" ]] && "$WINESERVER" -k || true
}

download_setup() {
    emit_info "Downloading TruckersMP setup"
    wget -O "$SETUP_EXE" "https://files.launcher.truckersmp.com/truckersmp-launcher/win/x64/TruckersMP-Setup.exe"
}

detect_truckersmp_path() {
    local base="$WINEPREFIX/dosdevices/c:/users/steamuser/AppData/Local/TruckersMP"
    [[ -d "$base" ]] || return 1

    local detected
    detected="$(find "$base" -maxdepth 1 -mindepth 1 -type d -name 'app-*' | sort -V | tail -n 1 || true)"
    [[ -n "$detected" ]] && { printf '%s\n' "$detected"; return 0; }

    [[ -f "$base/TruckersMP-Launcher.exe" ]] && { printf '%s\n' "$base"; return 0; }

    return 1
}

download_ipc_bridge() {
    emit_info "Downloading WineDiscordIPCBridge to stable location"
    mkdir -p "$STABLE_TMP_ROOT"
    wget -O "$STABLE_IPC_BRIDGE" \
        "https://raw.githubusercontent.com/rs189/TruckersMP-linux/main/TruckersMP.AppDir/usr/bin/winediscordipcbridge.exe"
    chmod +x "$STABLE_IPC_BRIDGE" || true
}

write_launcher_config() {
    mkdir -p "$(dirname "$STABLE_CONFIG_FILE")"

    cat > "$STABLE_CONFIG_FILE" <<EOF
STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH"
STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_COMPAT_CLIENT_INSTALL_PATH"
PROTON_EXEC="$PROTON_EXEC"
IPC_BRIDGE_EXE="$STABLE_IPC_BRIDGE"
EOF

    chmod 600 "$STABLE_CONFIG_FILE"
    emit_info "Launcher config written to $STABLE_CONFIG_FILE"
}

write_stable_launcher() {
    mkdir -p "$(dirname "$STABLE_LAUNCHER_SCRIPT")"

    cat > "$STABLE_LAUNCHER_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_FILE="${CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/truckersmp-launcher.conf}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing config: $CONFIG_FILE" >&2
    exit 1
fi

source "$CONFIG_FILE"

: "${STEAM_COMPAT_DATA_PATH:?STEAM_COMPAT_DATA_PATH is required}"
: "${STEAM_COMPAT_CLIENT_INSTALL_PATH:?STEAM_COMPAT_CLIENT_INSTALL_PATH is required}"
: "${PROTON_EXEC:?PROTON_EXEC is required}"

BASE_DIR="$STEAM_COMPAT_DATA_PATH/pfx/dosdevices/c:/users/steamuser/AppData/Local/TruckersMP"
APP_DIR="$(find "$BASE_DIR" -maxdepth 1 -mindepth 1 -type d -name 'app-*' | sort -V | tail -n 1 || true)"

if [[ -z "$APP_DIR" && -f "$BASE_DIR/TruckersMP-Launcher.exe" ]]; then
    APP_DIR="$BASE_DIR"
fi

if [[ -z "$APP_DIR" ]]; then
    echo "TruckersMP app directory not found under: $BASE_DIR" >&2
    exit 1
fi

LAUNCHER_EXE="$APP_DIR/TruckersMP-Launcher.exe"
IPC_BRIDGE_EXE="${IPC_BRIDGE_EXE:-$HOME/.local/share/TruckersMP/winediscordipcbridge.exe}"

[[ -f "$LAUNCHER_EXE" ]] || {
    echo "Launcher EXE not found: $LAUNCHER_EXE" >&2
    exit 1
}

[[ -x "$PROTON_EXEC" ]] || {
    echo "Proton executable not found or not executable: $PROTON_EXEC" >&2
    exit 1
}

export STEAM_COMPAT_DATA_PATH
export STEAM_COMPAT_CLIENT_INSTALL_PATH

IPC_BRIDGE_PID=""
LAUNCHER_PID=""

cleanup() {
    if [[ -n "${LAUNCHER_PID:-}" ]] && kill -0 "$LAUNCHER_PID" 2>/dev/null; then
        kill "$LAUNCHER_PID" 2>/dev/null || true
        wait "$LAUNCHER_PID" 2>/dev/null || true
    fi

    if [[ -n "${IPC_BRIDGE_PID:-}" ]] && kill -0 "$IPC_BRIDGE_PID" 2>/dev/null; then
        kill "$IPC_BRIDGE_PID" 2>/dev/null || true
        wait "$IPC_BRIDGE_PID" 2>/dev/null || true
    fi
}

trap cleanup EXIT INT TERM

cd "$APP_DIR"

if [[ -f "$IPC_BRIDGE_EXE" ]]; then
    "$PROTON_EXEC" run "$IPC_BRIDGE_EXE" >/dev/null 2>&1 &
    IPC_BRIDGE_PID=$!
fi

"$PROTON_EXEC" run "$LAUNCHER_EXE" >/dev/null 2>&1 &
LAUNCHER_PID=$!

wait "$LAUNCHER_PID"
EOF

    chmod +x "$STABLE_LAUNCHER_SCRIPT"
    emit_info "Stable launcher written to $STABLE_LAUNCHER_SCRIPT"
}

create_desktop_entry() {
    local menu_desktop_path="$APPLICATIONS_DIR/TruckersMP.desktop"
    local desktop_dir desktop_shortcut_path

    desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    desktop_dir="${desktop_dir:-$HOME/Desktop}"
    desktop_shortcut_path="$desktop_dir/TruckersMP.desktop"

    mkdir -p "$APPLICATIONS_DIR" "$desktop_dir"

    cat > "$menu_desktop_path" <<EOF
[Desktop Entry]
Name=TruckersMP
Exec=$STABLE_LAUNCHER_SCRIPT
Type=Application
Comment=Launcher for TruckersMP
Path=$HOME
StartupNotify=true
Icon=260A_TruckersMP-Launcher.0
StartupWMClass=truckersmp-launcher.exe
Terminal=false
Categories=Game;
EOF

    chmod 644 "$menu_desktop_path"
    cp -f "$menu_desktop_path" "$desktop_shortcut_path"
    chmod +x "$desktop_shortcut_path" || true

    emit_info "Menu shortcut created at $menu_desktop_path"
    emit_info "Desktop shortcut created at $desktop_shortcut_path"
}

update_game_path() {
    local selected_folder exe_unix exe_win json_file

    selected_folder="$(zenity --file-selection --directory --title="Path to the Euro Truck Simulator 2 directory" --filename="$ETS2_DIR/")" || {
        emit_error "No folder selected."
        exit 1
    }

    exe_unix="$selected_folder/bin/win_x64/eurotrucks2.exe"
    [[ -f "$exe_unix" ]] || {
        emit_error "eurotrucks2.exe was not found in selected directory."
        exit 1
    }

    exe_win="$(WINEPREFIX="$WINEPREFIX" "$WINE_BIN" winepath -w "$exe_unix" | tr -d '\r')"
    json_file="$WINEPREFIX/dosdevices/c:/users/steamuser/AppData/Roaming/TruckersMP/launcher-options.json"

    [[ -f "$json_file" ]] || {
        emit_error "launcher-options.json not found."
        exit 1
    }

    jq --arg newpath "$exe_win" \
       --argjson newopts '["-nointro"]' \
       '.games.ets2.path = $newpath | .games.ets2.consoleOpts = $newopts' \
       "$json_file" > "$TMP_DIR/launcher-options.json"

    mv "$TMP_DIR/launcher-options.json" "$json_file"
    emit_info "Updated launcher-options.json with ETS2 path: $exe_win"
}

run_installer() {
    [[ -x "${WINESERVER:-}" ]] && "$WINESERVER" -k || true
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" winecfg -v win10 || true
    WINEPREFIX="$WINEPREFIX" "$WINE_BIN" "$SETUP_EXE" || {
        emit_error "TruckersMP setup failed."
        exit 1
    }
}

wait_for_launcher_and_close() {
    emit_info "Waiting for launcher to appear"
    local timeout=30 elapsed=0

    while (( elapsed < timeout )); do
        if pgrep -f "TruckersMP-Launcher.exe" >/dev/null; then
            emit_info "Launcher detected, closing it"
            pkill -f "TruckersMP-Launcher.exe" || true
            sleep 2
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    emit_info "Launcher was not detected within timeout"
}

main() {
    emit_info "Starting TruckersMP installer v$VERSION"
    emit_info "Requested Proton runtime: $PROTON_NAME"

    check_dependencies

    STEAM_LIBRARY="$(find_ets2_library)" || {
        emit_error "ETS2 Steam library not found."
        exit 1
    }

    STEAM_ROOT="$(find_steam_root_for_library "$STEAM_LIBRARY" || true)"
    STEAM_ROOT="${STEAM_ROOT:-$HOME/.local/share/Steam}"
    ETS2_DIR="$STEAM_LIBRARY/steamapps/common/Euro Truck Simulator 2"
    WINEPREFIX="$STEAM_LIBRARY/steamapps/compatdata/${APP_ID_ETS2}/pfx"
    export WINEPREFIX WINEFSYNC=1

    PROTON_DIR="$(find_proton_dir || true)"
    if [[ -z "$PROTON_DIR" ]]; then
        emit_info "Requested Proton '$PROTON_NAME' not found, trying fallback autodetection"
        PROTON_DIR="$(autodetect_proton_dir || true)"
    fi

    [[ -n "$PROTON_DIR" ]] || {
        emit_error "No usable Proton installation was found."
        exit 1
    }

    PROTON_EXEC="$PROTON_DIR/proton"
    STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
    STEAM_COMPAT_DATA_PATH="$STEAM_LIBRARY/steamapps/compatdata/${APP_ID_ETS2}"
    export PROTON_DIR PROTON_EXEC STEAM_COMPAT_CLIENT_INSTALL_PATH STEAM_COMPAT_DATA_PATH

    emit_info "Using Proton runtime: $PROTON_DIR"

    init_wine_backend
    export WINESERVER WINE64 WINE_BIN USE_SYSTEM_WINE_FALLBACK

    check_wine_version
    ensure_prefix_ready
    check_appdata
    echo "PROGRESS:10"

    install_winetricks_corefonts
    echo "PROGRESS:60"

    download_setup
    echo "PROGRESS:70"

    run_installer
    echo "PROGRESS:80"

    wait_for_launcher_and_close

    TRUCKERSMP_PATH="$(detect_truckersmp_path)" || {
        emit_error "Installed TruckersMP path was not found."
        exit 1
    }

    emit_info "Detected current TruckersMP app path: $TRUCKERSMP_PATH"

    download_ipc_bridge
    write_launcher_config
    write_stable_launcher
    create_desktop_entry
    update_game_path

    echo "PROGRESS:100"
    echo "Starting TruckersMP Launcher"
    "$STABLE_LAUNCHER_SCRIPT" || true

    emit_info "TruckersMP installation completed"
}

main "$@"
