#!/usr/bin/env bash
# Stand-in for steamcmd.sh: "installs" the fake server and reports build ids
# from $FAKE_STATE/build (installed by app_update) and $FAKE_STATE/remote_build.
HERE="$(cd "$(dirname "$0")" && pwd)"
dir=""; mode=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        +force_install_dir) dir="$2"; shift ;;
        +app_update) mode=update ;;
        +app_info_print) mode=info ;;
    esac
    shift
done
remote="$(cat "$FAKE_STATE/remote_build" 2>/dev/null || echo 1000)"
if [[ "$mode" == update ]]; then
    echo "Update state (0x61) downloading, progress: 50.00 (1 / 2)"
    mkdir -p "$dir/steamapps"
    cp "$HERE/fake_valheim_server.py" "$dir/valheim_server.x86_64"; chmod +x "$dir/valheim_server.x86_64"
    printf '"AppState"\n{\n\t"appid"\t\t"896660"\n\t"buildid"\t\t"%s"\n}\n' "$remote" > "$dir/steamapps/appmanifest_896660.acf"
    echo "Success! App '896660' fully installed."
elif [[ "$mode" == info ]]; then
    printf '"896660"\n{\n\t"depots"\n\t{\n\t\t"branches"\n\t\t{\n\t\t\t"public"\n\t\t\t{\n\t\t\t\t"buildid"\t\t"%s"\n\t\t\t}\n\t\t}\n\t}\n}\n' "$remote"
fi
exit 0
