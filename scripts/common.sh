#!/usr/bin/env bash
# Shared settings and helpers. Sourced by the other scripts.

# ---- paths (the two volumes) -------------------------------------------------
: "${SERVER_DIR:=/opt/valheim}"          # game files, BepInEx, installed mods (re-downloadable)
: "${CONFIG_DIR:=/config}"               # everything you'd want to keep
SAVE_DIR="$CONFIG_DIR/saves"             # passed to -savedir; worlds live in saves/worlds_local
BACKUP_DIR="$CONFIG_DIR/backups"
LOG_DIR="$CONFIG_DIR/logs"
BEPINEX_CONFIG_DIR="$CONFIG_DIR/bepinex-config"
CUSTOM_PLUGINS_DIR="$CONFIG_DIR/custom-plugins"
export MODS_CACHE_DIR="$CONFIG_DIR/.thunderstore"
RUN_DIR="${RUN_DIR:-/tmp/valheim}"
STEAMCMD="${STEAMCMD:-/opt/steamcmd/steamcmd.sh}"
APP_ID=896660
SCRIPTS="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"

# ---- server settings ---------------------------------------------------------
: "${SERVER_NAME:=My Valheim Server}"
: "${WORLD_NAME:=Dedicated}"
: "${SERVER_PASS:=}"
: "${SERVER_PORT:=2456}"
: "${SERVER_PUBLIC:=false}"
: "${CROSSPLAY:=false}"
: "${WORLD_SEED:=}"
: "${WORLD_PRESET:=}"
: "${WORLD_MODIFIERS:=}"
: "${WORLD_KEYS:=}"
: "${ADMINS:=}"
: "${SAVE_INTERVAL:=}"
: "${SERVER_ARGS:=}"

# ---- updates -----------------------------------------------------------------
: "${AUTO_UPDATE:=true}"                 # master switch for the background checker
: "${SERVER_AUTO_UPDATE:=true}"          # Valheim itself
: "${MODS_AUTO_UPDATE:=true}"            # Thunderstore mods
: "${UPDATE_CHECK_INTERVAL:=60}"         # minutes
: "${UPDATE_WHEN_IDLE:=true}"            # wait for 0 players before restarting
: "${UPDATE_MAX_WAIT:=360}"              # minutes to wait for an empty server before restarting anyway (0 = forever)
: "${STEAM_BRANCH:=public}"
: "${STEAM_BRANCH_PASSWORD:=}"
: "${STEAM_VALIDATE:=false}"
: "${SKIP_STEAM_UPDATE:=false}"

# ---- backups / misc ----------------------------------------------------------
: "${BACKUP_ON_RESTART:=true}"
: "${BACKUP_KEEP:=10}"
: "${STOP_TIMEOUT:=90}"
: "${LOG_FILTER:=true}"

export SERVER_DIR CONFIG_DIR

log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}
info()  { log INFO "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }

truthy() {
    case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac
}

mods_wanted() {
    [[ -n "${MODS//[[:space:],;]/}" || -n "${THUNDERSTORE_PROFILE_CODE// /}" ]] || truthy "${BEPINEX_ENABLED:-false}" \
        || [[ -d "$CUSTOM_PLUGINS_DIR" && -n "$(ls -A "$CUSTOM_PLUGINS_DIR" 2>/dev/null)" ]]
}

# BepInEx is wanted for custom plugins too, so tell the mod manager about it.
if [[ -d "$CUSTOM_PLUGINS_DIR" && -n "$(ls -A "$CUSTOM_PLUGINS_DIR" 2>/dev/null)" ]]; then
    export BEPINEX_ENABLED=true
fi

installed_build() {
    local manifest="$SERVER_DIR/steamapps/appmanifest_${APP_ID}.acf"
    [[ -f "$manifest" ]] && grep -Po '"buildid"\s+"\K[0-9]+' "$manifest" | head -n1
}

# Latest build id for the configured branch. Tries the public steamcmd.net API
# first (fast), then asks steamcmd itself.
remote_build() {
    local build
    build="$(curl -fsS --max-time 30 "https://api.steamcmd.net/v1/info/${APP_ID}" 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['${APP_ID}']['depots']['branches']['${STEAM_BRANCH}']['buildid'])" 2>/dev/null)"
    if [[ -z "$build" ]]; then
        rm -f "$HOME/Steam/appcache/appinfo.vdf" "$(dirname "$STEAMCMD")/appcache/appinfo.vdf" 2>/dev/null
        build="$("$STEAMCMD" +login anonymous +app_info_update 1 +app_info_print "$APP_ID" +quit 2>/dev/null \
            | awk -v b="\"${STEAM_BRANCH}\"" '
                /"branches"/ { inb=1 }
                inb && $1 == b { inbr=1 }
                inbr && $1 == "\"buildid\"" { gsub(/"/, "", $2); print $2; exit }')"
    fi
    [[ "$build" =~ ^[0-9]+$ ]] && echo "$build"
}
