#!/usr/bin/env bash
# Background update checker. Every UPDATE_CHECK_INTERVAL minutes it looks for a
# new Valheim build and new Thunderstore mod versions. When something is new it
# waits for the server to be empty (if UPDATE_WHEN_IDLE), then asks the
# supervisor to restart; the supervisor installs the updates before starting.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

say() { info "[updater] $*"; }

server_pid() { cat "$RUN_DIR/server.pid" 2>/dev/null; }

players() {
    python3 "$SCRIPTS/player_count.py" 127.0.0.1 "$((SERVER_PORT + 1))" 2>/dev/null
}

check_updates() {
    REASONS=()
    if truthy "$SERVER_AUTO_UPDATE" && ! truthy "$SKIP_STEAM_UPDATE"; then
        local local_build remote
        local_build="$(installed_build)"
        remote="$(remote_build)"
        if [[ -n "$remote" && -n "$local_build" && "$remote" != "$local_build" ]]; then
            REASONS+=("Valheim update (build $local_build -> $remote)")
        elif [[ -z "$remote" ]]; then
            say "Could not check for Valheim updates this time"
        fi
    fi
    if truthy "$MODS_AUTO_UPDATE" && { mods_wanted || [[ -f "$SERVER_DIR/.thunderstore-state.json" ]]; }; then
        python3 "$SCRIPTS/thunderstore.py" check
        case $? in
            0) ;;
            10) REASONS+=("Thunderstore mod updates") ;;
            *) say "Could not check for mod updates this time" ;;
        esac
    fi
}

wait_for_idle() {
    truthy "$UPDATE_WHEN_IDLE" || return 0
    local waited=0 count unknown_logged=false
    while true; do
        [[ -z "$(server_pid)" ]] && return 1          # server not running (restarting/stopping)
        count="$(players)"
        if [[ "$count" == "0" ]]; then
            return 0
        elif [[ -n "$count" ]]; then
            (( waited % 15 == 0 )) && say "Update ready; waiting for $count player(s) to leave before restarting"
        elif ! $unknown_logged; then
            say "Can't read the player count (normal with crossplay); will restart after UPDATE_MAX_WAIT=${UPDATE_MAX_WAIT} min"
            unknown_logged=true
        fi
        if (( UPDATE_MAX_WAIT > 0 && waited >= UPDATE_MAX_WAIT )); then
            say "Waited ${waited} min for an empty server; restarting anyway"
            return 0
        fi
        sleep "${IDLE_POLL_SECONDS:-60}"
        waited=$((waited + 1))
    done
}

interval=$(( UPDATE_CHECK_INTERVAL > 0 ? UPDATE_CHECK_INTERVAL : 60 ))
sleep_s="${UPDATE_CHECK_SECONDS:-$(( interval * 60 ))}"   # seconds override, used by tests
say "Checking for updates every ${interval} min (Valheim: $SERVER_AUTO_UPDATE, mods: $MODS_AUTO_UPDATE, wait for empty server: $UPDATE_WHEN_IDLE)"
while true; do
    sleep "$sleep_s"
    [[ -z "$(server_pid)" ]] && continue
    check_updates
    (( ${#REASONS[@]} == 0 )) && continue
    say "Found: ${REASONS[*]}"
    wait_for_idle || continue
    pid="$(server_pid)"
    [[ -z "$pid" ]] && continue
    (IFS=';'; echo "${REASONS[*]}") > "$RUN_DIR/restart-reason"
    say "Restarting the server to apply updates"
    kill -INT "$pid" 2>/dev/null
done
