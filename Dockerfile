# Valheim dedicated server for Unraid, with Thunderstore mods, automatic
# updates and a choosable world seed. The game itself is downloaded at first
# start (and updated later) by SteamCMD, so the image stays small.
FROM debian:bookworm-slim

ARG DEBIAN_FRONTEND=noninteractive
# Set to 0 only for offline tests (no SteamCMD in the image).
ARG INSTALL_STEAMCMD=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl tini gosu procps tar gzip tzdata \
        lib32gcc-s1 lib32stdc++6 libatomic1 libpulse0 libc6 \
        python3 python3-yaml \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g 100 -o valheim \
 && useradd -u 99 -o -g valheim -d /home/valheim -m -s /bin/bash valheim \
 && mkdir -p /opt/steamcmd \
 && if [ "$INSTALL_STEAMCMD" = "1" ]; then \
        curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
            | tar -xz -C /opt/steamcmd; \
    fi \
 && chown -R valheim:valheim /opt/steamcmd

COPY --chmod=755 scripts/ /usr/local/lib/valheim/
# Strip Windows line endings in case the files were edited on Windows.
RUN sed -i 's/\r$//' /usr/local/lib/valheim/*

ENV HOME=/home/valheim \
    SERVER_DIR=/opt/valheim \
    CONFIG_DIR=/config \
    PUID=99 \
    PGID=100 \
    TZ=Etc/UTC

VOLUME ["/config", "/opt/valheim"]
EXPOSE 2456/udp 2457/udp

HEALTHCHECK --interval=1m --timeout=10s --start-period=20m --retries=3 \
    CMD pgrep -f valheim_server.x86_64 >/dev/null || exit 1

STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "bash", "/usr/local/lib/valheim/entrypoint.sh"]
