#!/usr/bin/env bash
# Offline tests for scripts/thunderstore.py against tests/mock_thunderstore.py
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# Files committed from Windows lose their executable bit; restore it.
chmod +x "$HERE"/*.sh "$HERE"/*.py "$HERE"/../scripts/*.sh "$HERE"/../scripts/*.py 2>/dev/null
TS="$HERE/../scripts/thunderstore.py"
PORT=8765
export THUNDERSTORE_URL="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
SRV="$WORK/server"; CACHE="$WORK/cache"
mkdir -p "$SRV"
python3 "$HERE/mock_thunderstore.py" $PORT & MOCK=$!
trap 'kill $MOCK 2>/dev/null; rm -rf "$WORK"' EXIT
sleep 1

fails=0
ok()   { echo "  PASS $1"; }
bad()  { echo "  FAIL $1"; fails=$((fails+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }
run()  { python3 "$TS" "$@" --server-dir "$SRV" --cache-dir "$CACHE"; }
P="$SRV/BepInEx/plugins"

echo "== 1. fresh install with dependencies, URL form and pinned version"
export MODS="Azumatt-AzuCraftyBoxes, https://thunderstore.io/c/valheim/p/Smoothbrain/ServerCharacters/
Nested-PatcherMod"
run sync; check "sync exit 0" "[ $? -eq 0 ]"
check "BepInEx core installed" "[ -f $SRV/BepInEx/core/BepInEx.Preloader.dll ]"
check "doorstop lib in server root" "[ -f $SRV/libdoorstop.so ]"
check "start script executable" "[ -x $SRV/start_server_bepinex.sh ]"
check "Jotunn dependency installed (latest, not 2.12.0)" "grep -q jotunn-2.20.0 $P/ValheimModding-Jotunn/Jotunn.dll"
check "backslash zip paths handled" "[ -f $P/Azumatt-AzuCraftyBoxes/AzuCraftyBoxes.dll ]"
check "mod config copied to BepInEx/config" "grep -q from-zip $SRV/BepInEx/config/Azumatt.AzuCraftyBoxes.cfg"
check "loose dll goes to plugins/<id>" "[ -f $P/Smoothbrain-ServerCharacters/ServerCharacters.dll ]"
check "nested BepInEx/plugins handled" "[ -f $P/Nested-PatcherMod/PatcherMod/PatcherMod.dll ]"
check "patchers go to BepInEx/patchers/<id>" "[ -f $SRV/BepInEx/patchers/Nested-PatcherMod/PatcherMod.Patch.dll ]"

echo "== 2. nothing to do, check says up to date"
run check; check "check exit 0" "[ $? -eq 0 ]"

echo "== 3. user edits a config, a new mod release appears"
echo "user-edited" > "$SRV/BepInEx/config/Azumatt.AzuCraftyBoxes.cfg"
curl -s -X POST "$THUNDERSTORE_URL/_release/Azumatt/AzuCraftyBoxes/1.6.0" >/dev/null
run check; check "check reports update (exit 10)" "[ $? -eq 10 ]"
run sync >/dev/null
check "mod updated" "grep -q 'acb-1.6.0' $P/Azumatt-AzuCraftyBoxes/AzuCraftyBoxes.dll"
check "user config kept" "grep -q user-edited $SRV/BepInEx/config/Azumatt.AzuCraftyBoxes.cfg"

echo "== 4. pinned versions are not updated"
export MODS="Azumatt-AzuCraftyBoxes Smoothbrain-ServerCharacters-1.4.0 Nested-PatcherMod"
run sync >/dev/null
check "pinned version installed" "grep -q sc-1.4.0 $P/Smoothbrain-ServerCharacters/ServerCharacters.dll"
curl -s -X POST "$THUNDERSTORE_URL/_release/Smoothbrain/ServerCharacters/1.6.0" >/dev/null
run check >/dev/null; check "no update for pinned mod" "[ $? -eq 0 ]"

echo "== 5. removing a mod from the list uninstalls it"
export MODS="Azumatt-AzuCraftyBoxes"
run sync >/dev/null
check "ServerCharacters removed" "[ ! -e $P/Smoothbrain-ServerCharacters ]"
check "patcher removed" "[ ! -e $SRV/BepInEx/patchers/Nested-PatcherMod ]"
check "dependency kept" "[ -e $P/ValheimModding-Jotunn ]"
check "configs never deleted" "[ -f $SRV/BepInEx/config/Azumatt.AzuCraftyBoxes.cfg ]"

echo "== 6. unknown mod: error, nothing removed"
export MODS="Azumatt-AzuCraftyBoxes Nobody-DoesNotExist"
run sync; check "sync exit 1 on unknown mod" "[ $? -eq 1 ]"
check "existing mods untouched" "[ -e $P/Azumatt-AzuCraftyBoxes ]"

echo "== 7. profile code with exclude list"
export MODS="" THUNDERSTORE_PROFILE_CODE="good-code" MODS_EXCLUDE="RandyKnapp-EquipmentAndQuickSlots"
run sync >/dev/null; check "profile sync exit 0" "[ $? -eq 0 ]"
check "profile mod installed at latest" "grep -q "1.6.0$" $P/Smoothbrain-ServerCharacters/ServerCharacters.dll"
check "excluded client mod not installed" "[ ! -e $P/RandyKnapp-EquipmentAndQuickSlots ]"
check "disabled profile mod not installed" "[ ! -e $P/Nested-PatcherMod ]"
check "mods not in profile removed" "[ ! -e $P/Azumatt-AzuCraftyBoxes ]"
check "profile config imported" "grep -q from-profile $SRV/BepInEx/config/Smoothbrain.ServerCharacters.cfg"
check "non-config files in profile ignored" "[ ! -e $SRV/BepInEx/config/evil.dll ]"

echo "== 8. pinned profile versions"
export PROFILE_PIN_VERSIONS=true
run sync >/dev/null
check "profile pinned version used" "grep -q sc-1.4.0 $P/Smoothbrain-ServerCharacters/ServerCharacters.dll"

echo "== 9. expired profile code falls back to saved copy"
cp "$CACHE/profile-good-code.zip" "$CACHE/profile-expired-code.zip"
export THUNDERSTORE_PROFILE_CODE="expired-code"
run sync >/dev/null; check "sync with expired code uses cache" "[ $? -eq 0 ]"

echo "== 10. Thunderstore down: mods stay installed"
kill $MOCK; sleep 0.5
run sync >/dev/null 2>&1; check "sync fails" "[ $? -ne 0 ]"
check "installed mods kept" "[ -e $P/Smoothbrain-ServerCharacters ] && [ -f $SRV/BepInEx/core/BepInEx.Preloader.dll ]"

echo "== 11. no mods configured: BepInEx removed"
python3 "$HERE/mock_thunderstore.py" $PORT & MOCK=$!; sleep 1
export THUNDERSTORE_PROFILE_CODE="" MODS=""
run sync >/dev/null
check "BepInEx core removed" "[ ! -e $SRV/BepInEx/core ]"
check "doorstop removed" "[ ! -e $SRV/libdoorstop.so ]"
check "configs kept" "[ -f $SRV/BepInEx/config/BepInEx.cfg ]"

echo
if [ $fails -eq 0 ]; then echo "ALL MOD TESTS PASSED"; else echo "$fails MOD TEST(S) FAILED"; exit 1; fi
