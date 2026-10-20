#!/usr/bin/env bash
# Runs the Valheim server: update -> sync mods -> prepare world -> start,
# restarting it when the background updater asks, and stopping it cleanly
# (world saved) when the container stops.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/common.sh"

SERVER_PID=""
UPDATER_PID=""
STOPPING=false
mkdir -p "$RUN_DIR" "$SAVE_DIR" "$BACKUP_DIR" "$LOG_DIR" "$BEPINEX_CONFIG_DIR" "$SERVER_DIR"
rm -f "$RUN_DIR"/*

on_stop() {
    STOPPING=true
    info "Stop requested, saving world and shutting down..."
    [[ -n "$UPDATER_PID" ]] && kill "$UPDATER_PID" 2>/dev/null
    [[ -n "$SERVER_PID" ]] && kill -INT "$SERVER_PID" 2>/dev/null
}
trap on_stop TERM INT

# ------------------------------------------------------------------ steps

update_server() {
    if truthy "$SKIP_STEAM_UPDATE"; then
        info "SKIP_STEAM_UPDATE is set, not updating Valheim"
        return 0
    fi
    local args=(+force_install_dir "$SERVER_DIR" +login anonymous +app_update "$APP_ID")
    if [[ -n "$STEAM_BRANCH" && "$STEAM_BRANCH" != "public" ]]; then
        args+=(-beta "$STEAM_BRANCH")
        [[ -n "$STEAM_BRANCH_PASSWORD" ]] && args+=(-betapassword "$STEAM_BRANCH_PASSWORD")
    fi
    truthy "$STEAM_VALIDATE" && args+=(validate)
    args+=(+quit)

    local before attempt out="$RUN_DIR/steamcmd.out"
    before="$(installed_build)"
    info "Checking Valheim server files (branch: $STEAM_BRANCH, installed build: ${before:-none})..."
    for attempt in 1 2 3; do
        "$STEAMCMD" "${args[@]}" 2>&1 | tee "$out" | grep --line-buffered -E "Success|Error|ERROR|progress:" 
        if grep -q "Success! App '$APP_ID'" "$out" && [[ -x "$SERVER_DIR/valheim_server.x86_64" ]]; then
            break
        fi
        warn "steamcmd attempt $attempt did not finish, retrying..."
        sleep 10
    done
    if [[ ! -x "$SERVER_DIR/valheim_server.x86_64" ]]; then
        error "Valheim server files are missing and could not be downloaded."
        return 1
    fi
    local after; after="$(installed_build)"
    [[ "$before" != "$after" ]] && info "Valheim updated: ${before:-none} -> $after"
    return 0
}

link_bepinex_config() {
    # Keep mod configs in /config so they survive and are easy to edit.
    local cfg="$SERVER_DIR/BepInEx/config"
    mkdir -p "$SERVER_DIR/BepInEx"
    if [[ -d "$cfg" && ! -L "$cfg" ]]; then
        cp -an "$cfg"/. "$BEPINEX_CONFIG_DIR"/ 2>/dev/null
        rm -rf "$cfg"
    fi
    [[ -L "$cfg" ]] || ln -s "$BEPINEX_CONFIG_DIR" "$cfg"
}

sync_mods() {
    link_bepinex_config
    if ! mods_wanted && [[ ! -f "$SERVER_DIR/.thunderstore-state.json" ]]; then
        return 0
    fi
    info "Syncing Thunderstore mods..."
    if ! python3 "$SCRIPTS/thunderstore.py" sync; then
        warn "Some mods could not be installed or updated (see above). Starting with what is installed."
    fi
    # Your own plugins (DLLs not on Thunderstore) from /config/custom-plugins
    local custom="$SERVER_DIR/BepInEx/plugins/_custom"
    rm -rf "$custom"
    if [[ -d "$CUSTOM_PLUGINS_DIR" && -n "$(ls -A "$CUSTOM_PLUGINS_DIR" 2>/dev/null)" ]]; then
        mkdir -p "$custom"
        cp -a "$CUSTOM_PLUGINS_DIR"/. "$custom"/
        info "Added custom plugins: $(cd "$CUSTOM_PLUGINS_DIR" && find . -name '*.dll' | sed 's|^\./||' | paste -sd ', ')"
    fi
}

prepare_world() {
    local existing
    existing="$(python3 "$SCRIPTS/valheim_world.py" find --savedir "$SAVE_DIR" --name "$WORLD_NAME" 2>/dev/null)"
    if [[ -n "$WORLD_SEED" ]]; then
        if python3 "$SCRIPTS/valheim_world.py" exists --savedir "$SAVE_DIR" --name "$WORLD_NAME"; then
            if [[ -n "$existing" && "$existing" != "$WORLD_SEED" ]]; then
                warn "World '$WORLD_NAME' already exists with seed '$existing'. WORLD_SEED ($WORLD_SEED) only applies to NEW worlds - change WORLD_NAME to start a new world with it."
            fi
        else
            python3 "$SCRIPTS/valheim_world.py" create --savedir "$SAVE_DIR" --name "$WORLD_NAME" --seed "$WORLD_SEED" \
                || error "Could not create world with seed '$WORLD_SEED'; the server will use a random seed."
            existing="$WORLD_SEED"
        fi
    fi
    [[ -n "$existing" ]] && info "World: $WORLD_NAME (seed: $existing)" || info "World: $WORLD_NAME (new, random seed)"
}

write_admin_list() {
    [[ -z "${ADMINS// /}" ]] && return 0
    {
        echo "// Managed by the container from the ADMINS setting. Edits here are overwritten on restart."
        tr ', ;' '\n\n\n' <<<"$ADMINS" | sed '/^$/d'
    } > "$SAVE_DIR/adminlist.txt"
}

backup_world() {
    truthy "$BACKUP_ON_RESTART" || return 0
    local files=()
    [[ -d "$SAVE_DIR/worlds_local/$WORLD_NAME" ]] && files+=("worlds_local/$WORLD_NAME")
    for f in worlds_local/"$WORLD_NAME".{db,fwl} worlds/"$WORLD_NAME".{db,fwl}; do
        [[ -f "$SAVE_DIR/$f" ]] && files+=("$f")
    done
    [[ ${#files[@]} -eq 0 ]] && return 0
    # Nothing to back up yet if the world folder only holds the seed metadata we created.
    if [[ ${#files[@]} -eq 1 && "$(ls -A "$SAVE_DIR/worlds_local/$WORLD_NAME" 2>/dev/null)" == "_main.0.fwl2" ]]; then
        return 0
    fi
    local name="$BACKUP_DIR/${WORLD_NAME}-$(date +%Y%m%d-%H%M%S).tar.gz"
    if tar -czf "$name" -C "$SAVE_DIR" "${files[@]}" 2>/dev/null; then
        info "World backed up to backups/$(basename "$name")"
    else
        warn "World backup failed"; rm -f "$name"
    fi
    # keep the newest BACKUP_KEEP backups of this world
    ls -1t "$BACKUP_DIR/${WORLD_NAME}-"*.tar.gz 2>/dev/null | tail -n +"$((BACKUP_KEEP + 1))" | xargs -r rm -f
}

build_args() {
    ARGS=(-nographics -batchmode -name "$SERVER_NAME" -port "$SERVER_PORT" -world "$WORLD_NAME" -savedir "$SAVE_DIR")
    truthy "$SERVER_PUBLIC" && ARGS+=(-public 1) || ARGS+=(-public 0)
    if [[ -n "$SERVER_PASS" ]]; then
        ARGS+=(-password "$SERVER_PASS")
        (( ${#SERVER_PASS} < 5 )) && warn "Valheim requires a password of at least 5 characters."
        [[ "${SERVER_NAME,,}" == *"${SERVER_PASS,,}"* ]] && warn "Valheim refuses passwords that are part of the server name."
    else
        warn "No SERVER_PASS set. Valheim may refuse to start without a password."
    fi
    truthy "$CROSSPLAY" && ARGS+=(-crossplay)
    [[ -n "$WORLD_PRESET" ]] && ARGS+=(-preset "${WORLD_PRESET,,}")
    local item key value
    for item in $(tr ',;' '  ' <<<"$WORLD_MODIFIERS"); do
        key="${item%%[:=]*}"; value="${item#*[:=]}"
        [[ "$key" == "$item" ]] && { warn "Ignoring modifier '$item' (use name:value, e.g. combat:hard)"; continue; }
        ARGS+=(-modifier "${key,,}" "${value,,}")
    done
    for item in $(tr ',;' '  ' <<<"$WORLD_KEYS"); do
        ARGS+=(-setkey "${item,,}")
    done
    [[ -n "$SAVE_INTERVAL" ]] && ARGS+=(-saveinterval "$SAVE_INTERVAL")
    if [[ -n "$SERVER_ARGS" ]]; then
        local extra; read -r -a extra <<<"$SERVER_ARGS"; ARGS+=("${extra[@]}")
    fi
}

build_env() {
    ENVS=("SteamAppId=892970" "LD_LIBRARY_PATH=$SERVER_DIR/linux64:${LD_LIBRARY_PATH:-}")
    if [[ -f "$SERVER_DIR/BepInEx/core/BepInEx.Preloader.dll" ]]; then
        local lib
        lib="$(find "$SERVER_DIR" -maxdepth 3 \( -name 'libdoorstop_x64.so' -o -name 'libdoorstop.so' \) \
            -not -path '*/plugins/*' 2>/dev/null | head -n1)"
        if [[ -z "$lib" ]]; then
            warn "BepInEx is installed but libdoorstop was not found; starting without mods."
            return
        fi
        local preloader="$SERVER_DIR/BepInEx/core/BepInEx.Preloader.dll"
        ENVS=("SteamAppId=892970"
              "LD_LIBRARY_PATH=$(dirname "$lib"):$SERVER_DIR/linux64:${LD_LIBRARY_PATH:-}"
              "LD_PRELOAD=$lib"
              # doorstop 3 (older BepInExPack)
              "DOORSTOP_ENABLE=TRUE" "DOORSTOP_INVOKE_DLL_PATH=$preloader"
              # doorstop 4 (BepInExPack 5.4.2330+)
              "DOORSTOP_ENABLED=1" "DOORSTOP_TARGET_ASSEMBLY=$preloader")
        [[ -d "$SERVER_DIR/unstripped_corlib" ]] && ENVS+=("DOORSTOP_CORLIB_OVERRIDE_PATH=$SERVER_DIR/unstripped_corlib")
        info "Starting with BepInEx ($(python3 "$SCRIPTS/thunderstore.py" list 2>/dev/null | wc -l) Thunderstore packages)"
    fi
}

log_filter() {
    if truthy "$LOG_FILTER"; then
        # Drop Unity's noise: blank lines and "(Filename: ... Line: N)" trailers.
        grep --line-buffered -v -E '^\s*$|^\(Filename: |^Setting up [0-9]+ worker threads|^\s+(Thread|Fallback) '
    else
        cat
    fi
}

start_server() {
    build_args
    build_env
    local logfile="$LOG_DIR/valheim.log"
    for i in 3 2 1; do [[ -f "$logfile.$i" ]] && mv -f "$logfile.$i" "$logfile.$((i + 1))"; done
    [[ -f "$logfile" ]] && mv -f "$logfile" "$logfile.1"
    rm -f "$logfile.5"

    local shown=("${ARGS[@]}") i
    for i in "${!shown[@]}"; do [[ "${shown[$((i-1))]:-}" == "-password" ]] && shown[$i]="********"; done
    info "Launching: valheim_server.x86_64 ${shown[*]}"

    cd "$SERVER_DIR" || return 1
    env "${ENVS[@]}" "$SERVER_DIR/valheim_server.x86_64" "${ARGS[@]}" \
        > >(log_filter | tee -a "$logfile") 2>&1 &
    SERVER_PID=$!
    echo "$SERVER_PID" > "$RUN_DIR/server.pid"
}

start_updater() {
    truthy "$AUTO_UPDATE" || { info "Automatic updates are off"; return; }
    bash "$SCRIPTS/updater.sh" &
    UPDATER_PID=$!
}

# ------------------------------------------------------------------ main loop

info "Valheim server container starting (server files: $SERVER_DIR, data: $CONFIG_DIR)"
start_updater
crashes=0
while true; do
    $STOPPING && break
    update_server || { error "Retrying in 5 minutes"; sleep 300 & wait $!; continue; }
    $STOPPING && break
    sync_mods
    prepare_world
    write_admin_list
    backup_world
    $STOPPING && break

    started=$(date +%s)
    code=0
    start_server
    # `wait` returns early when a signal arrives; keep waiting until the server is gone.
    while kill -0 "$SERVER_PID" 2>/dev/null; do
        wait "$SERVER_PID"
        code=$?
        if $STOPPING; then
            for _ in $(seq "$STOP_TIMEOUT"); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 1; done
            if kill -0 "$SERVER_PID" 2>/dev/null; then
                warn "Server did not stop within ${STOP_TIMEOUT}s, killing it"
                kill -KILL "$SERVER_PID" 2>/dev/null
            fi
        fi
    done
    SERVER_PID=""
    rm -f "$RUN_DIR/server.pid"
    $STOPPING && break

    if [[ -f "$RUN_DIR/restart-reason" ]]; then
        info "Restarting: $(cat "$RUN_DIR/restart-reason")"
        rm -f "$RUN_DIR/restart-reason"
        crashes=0
        continue
    fi

    # Unexpected exit: back off if it keeps crashing right after starting.
    if (( $(date +%s) - started < 300 )); then crashes=$((crashes + 1)); else crashes=1; fi
    delay=$(( crashes >= 5 ? 300 : ${CRASH_RESTART_DELAY:-15} ))
    error "Valheim server exited unexpectedly (code $code). Restarting in ${delay}s... (logs: logs/valheim.log)"
    sleep "$delay" & wait $!
done

[[ -n "$UPDATER_PID" ]] && kill "$UPDATER_PID" 2>/dev/null
sleep 1   # let the log pipe flush the server's last lines
info "Server stopped."
exit 0
