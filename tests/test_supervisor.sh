#!/usr/bin/env bash
# End-to-end test of supervisor.sh + updater.sh with a fake Valheim server,
# fake SteamCMD and the mock Thunderstore API. Runs without Docker or network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Files committed from Windows lose their executable bit; restore it.
chmod +x "$HERE"/*.sh "$HERE"/*.py "$HERE"/../scripts/*.sh "$HERE"/../scripts/*.py 2>/dev/null
S="$HERE/../scripts"
WORK="$(mktemp -d)"
PORT=8766

export FAKE_STATE="$WORK/fake" CONFIG_DIR="$WORK/config" SERVER_DIR="$WORK/server" RUN_DIR="$WORK/run"
export STEAMCMD="$HERE/fake_steamcmd.sh" THUNDERSTORE_URL="http://127.0.0.1:$PORT"
export SERVER_NAME="Test Server" WORLD_NAME="Testworld" SERVER_PASS="hunter22" SERVER_PORT=24560
export WORLD_SEED="TestSeed1" WORLD_PRESET="hard" WORLD_MODIFIERS="combat:veryhard, raids=none" WORLD_KEYS="nomap"
export ADMINS="76561190000000001, 76561190000000002" MODS="Azumatt-AzuCraftyBoxes"
export UPDATE_CHECK_SECONDS=3 IDLE_POLL_SECONDS=1 UPDATE_MAX_WAIT=0 CRASH_RESTART_DELAY=1 STOP_TIMEOUT=10
mkdir -p "$FAKE_STATE" "$CONFIG_DIR/custom-plugins/MyPlugin"
echo 1000 > "$FAKE_STATE/remote_build"
echo 0 > "$FAKE_STATE/players"
echo dll > "$CONFIG_DIR/custom-plugins/MyPlugin/MyPlugin.dll"

python3 "$HERE/mock_thunderstore.py" $PORT & MOCK=$!
OUT="$WORK/supervisor.out"
cleanup() { kill $MOCK $SUP 2>/dev/null; pkill -f "$SERVER_DIR/valheim_server" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
sleep 1

fails=0
ok()  { echo "  PASS $1"; }
bad() { echo "  FAIL $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
wait_for() { # pattern timeout
    for _ in $(seq $(( $2 * 2 ))); do grep -q -- "$1" "$OUT" && return 0; sleep 0.5; done
    echo "  (timed out waiting for: $1)"; return 1
}
starts() { wc -l < "$FAKE_STATE/starts" 2>/dev/null || echo 0; }

"$S/supervisor.sh" > "$OUT" 2>&1 & SUP=$!

echo "== first start"
check "server launched" "wait_for 'Fake Valheim server started' 20"
A="$FAKE_STATE/args"
check "name/world/port/savedir passed" "grep -qx 'Test Server' $A && grep -qx Testworld $A && grep -qx 24560 $A && grep -qx $CONFIG_DIR/saves $A"
check "password passed and masked in output" "grep -qx hunter22 $A && ! grep -q hunter22 $OUT"
check "preset/modifiers/keys passed" "tr '\n' ' ' < $A | grep -q -- '-preset hard -modifier combat veryhard -modifier raids none -setkey nomap'"
check "private by default" "tr '\n' ' ' < $A | grep -q -- '-public 0'"
check "BepInEx preloaded" "grep -q 'LD_PRELOAD=$SERVER_DIR/libdoorstop.so' $FAKE_STATE/env && grep -q DOORSTOP_ENABLED=1 $FAKE_STATE/env"
check "mod installed" "[ -f $SERVER_DIR/BepInEx/plugins/Azumatt-AzuCraftyBoxes/AzuCraftyBoxes.dll ]"
check "custom plugin copied" "[ -f $SERVER_DIR/BepInEx/plugins/_custom/MyPlugin/MyPlugin.dll ]"
check "BepInEx config lives in /config" "[ -L $SERVER_DIR/BepInEx/config ] && [ -f $CONFIG_DIR/bepinex-config/BepInEx.cfg ]"
check "world created with seed" "python3 $S/valheim_world.py find --savedir $CONFIG_DIR/saves --name Testworld | grep -qx TestSeed1"
check "admin list written" "grep -qx 76561190000000002 $CONFIG_DIR/saves/adminlist.txt"
check "log file written and filtered" "grep -q 'Game server connected' $CONFIG_DIR/logs/valheim.log && ! grep -q '(Filename:' $CONFIG_DIR/logs/valheim.log"

echo "== mod update waits for players to leave"
echo 2 > "$FAKE_STATE/players"
curl -s -X POST "$THUNDERSTORE_URL/_release/Azumatt/AzuCraftyBoxes/1.6.0" >/dev/null
check "updater found mod update" "wait_for 'Found: Thunderstore mod updates' 20"
check "waits for players" "wait_for 'waiting for 2 player' 10"
sleep 3
check "no restart while players online" "[ \$(starts) -eq 1 ]"
echo 0 > "$FAKE_STATE/players"
check "restarts once empty" "wait_for 'Restarting: Thunderstore mod updates' 15"
check "server came back" "for i in \$(seq 30); do [ \$(starts) -eq 2 ] && break; sleep 0.5; done; [ \$(starts) -eq 2 ]"
check "world saved before restart" "[ -f $FAKE_STATE/saved ]"
check "new mod version installed" "grep -q '1.6.0' $SERVER_DIR/BepInEx/plugins/Azumatt-AzuCraftyBoxes/AzuCraftyBoxes.dll"
check "world backed up" "ls $CONFIG_DIR/backups/Testworld-*.tar.gz >/dev/null 2>&1"

echo "== Valheim update"
echo 1001 > "$FAKE_STATE/remote_build"
check "updater found game update" "wait_for 'Valheim update (build 1000 -> 1001)' 20"
check "restarted and updated" "wait_for 'Valheim updated: 1000 -> 1001' 20"

echo "== crash recovery"
sleep 2
before=$(starts)
pkill -9 -f "$SERVER_DIR/valheim_server"
check "crash noticed" "wait_for 'exited unexpectedly' 10"
check "restarted after crash" "for i in \$(seq 30); do [ \$(starts) -gt $before ] && break; sleep 0.5; done; [ \$(starts) -gt $before ]"

echo "== container stop saves the world"
sleep 2
rm -f "$FAKE_STATE/saved"
kill -TERM $SUP
for _ in $(seq 20); do kill -0 $SUP 2>/dev/null || break; sleep 0.5; done
check "supervisor exited" "! kill -0 $SUP 2>/dev/null"
check "server saved on stop" "[ -f $FAKE_STATE/saved ]"
check "server process gone" "! pgrep -f $SERVER_DIR/valheim_server >/dev/null"
check "clean shutdown message" "grep -q 'Server stopped.' $OUT"

echo "== changed seed on existing world only warns"
export WORLD_SEED="OtherSeed"
"$S/supervisor.sh" > "$OUT" 2>&1 & SUP=$!
check "warning shown" "wait_for 'only applies to NEW worlds' 20"
check "original seed kept" "python3 $S/valheim_world.py find --savedir $CONFIG_DIR/saves --name Testworld | grep -qx TestSeed1"
kill -TERM $SUP; sleep 3

echo
if [ $fails -eq 0 ]; then echo "ALL SUPERVISOR TESTS PASSED"; else echo "$fails SUPERVISOR TEST(S) FAILED"; echo "---- output ----"; cat "$OUT"; exit 1; fi
