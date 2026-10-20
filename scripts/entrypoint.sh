#!/usr/bin/env bash
# Runs as root: match the container user to Unraid's PUID/PGID (99:100 =
# nobody:users by default), fix ownership, then drop privileges.
set -euo pipefail
PUID="${PUID:-99}"
PGID="${PGID:-100}"

if [[ "$(id -u)" != "0" ]]; then
    exec bash /usr/local/lib/valheim/supervisor.sh
fi

groupmod -o -g "$PGID" valheim >/dev/null
usermod -o -u "$PUID" -g "$PGID" valheim >/dev/null
umask "${UMASK:-0002}"

for dir in /config /opt/valheim /opt/steamcmd /home/valheim; do
    mkdir -p "$dir"
    # Only touch files with the wrong owner (fast on big folders).
    find "$dir" -xdev \( ! -user "$PUID" -o ! -group "$PGID" \) -print0 2>/dev/null \
        | xargs -0 -r chown -h "$PUID:$PGID"
done

exec gosu valheim:valheim bash /usr/local/lib/valheim/supervisor.sh
