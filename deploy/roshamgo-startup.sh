#!/bin/bash
set -uo pipefail

BINARY_PATH="/home/roshamgo/ROSHAMGO"
GITHUB_REPO="mikemahony/roshamgo-device"
GITHUB_RAW="https://raw.githubusercontent.com/${GITHUB_REPO}/main/deploy"
ASSET_NAME="roshamgo-device-linux-aarch64"
LISTEN_PORT=3000
RESTART_SECRET="restart"
SIGNAL_FILE="/tmp/roshamgo-do-restart"
SELF_UPDATE_DONE="/tmp/roshamgo-self-updated"
FIFO=$(mktemp -u /tmp/roshamgo-fifo.XXXXXX)

BINARY_PID=""

log() {
    echo "[roshamgo-startup] $(date '+%Y-%m-%d %H:%M:%S') $1"
}

self_update() {
    if [ -f "$SELF_UPDATE_DONE" ]; then
        return
    fi
    touch "$SELF_UPDATE_DONE"

    log "Checking for script updates from GitHub..."

    # Update service file (env vars live here)
    if curl -sfL --connect-timeout 5 -o /tmp/roshamgo.service.new "${GITHUB_RAW}/roshamgo.service" 2>/dev/null; then
        if ! cmp -s /tmp/roshamgo.service.new /etc/systemd/system/roshamgo.service; then
            cp /tmp/roshamgo.service.new /etc/systemd/system/roshamgo.service
            systemctl daemon-reload
            log "Updated roshamgo.service"
        fi
        rm -f /tmp/roshamgo.service.new
    fi

    # Update this script
    local self_path="$(readlink -f "$0")"
    if curl -sfL --connect-timeout 5 -o /tmp/roshamgo-startup.sh.new "${GITHUB_RAW}/roshamgo-startup.sh" 2>/dev/null; then
        if ! cmp -s /tmp/roshamgo-startup.sh.new "$self_path"; then
            cp /tmp/roshamgo-startup.sh.new "$self_path"
            chmod +x "$self_path"
            rm -f /tmp/roshamgo-startup.sh.new
            log "Updated startup script — re-executing..."
            exec "$self_path"
        fi
        rm -f /tmp/roshamgo-startup.sh.new
    fi
}

self_update

download_latest_binary() {
    log "Checking for latest release from GitHub..."
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local response
    response=$(curl -sL --connect-timeout 10 --max-time 30 "$api_url" 2>/dev/null)

    if [ -z "$response" ]; then
        log "WARNING: Could not reach GitHub API"
        check_existing_binary
        return
    fi

    local download_url
    download_url=$(echo "$response" | jq -r ".assets[] | select(.name == \"${ASSET_NAME}\") | .browser_download_url" 2>/dev/null)

    if [ -z "$download_url" ] || [ "$download_url" = "null" ]; then
        log "WARNING: No asset '${ASSET_NAME}' found in latest release"
        check_existing_binary
        return
    fi

    log "Downloading from: $download_url"
    if curl -sL --connect-timeout 10 --max-time 120 -o "${BINARY_PATH}.tmp" "$download_url" 2>/dev/null; then
        local filesize
        filesize=$(stat -c%s "${BINARY_PATH}.tmp" 2>/dev/null || stat -f%z "${BINARY_PATH}.tmp" 2>/dev/null || echo "0")
        if [ "$filesize" -gt 0 ]; then
            mv "${BINARY_PATH}.tmp" "$BINARY_PATH"
            chmod +x "$BINARY_PATH"
            log "Downloaded latest binary (${filesize} bytes)"
            return
        fi
    fi

    rm -f "${BINARY_PATH}.tmp"
    log "WARNING: Download failed"
    check_existing_binary
}

check_existing_binary() {
    if [ -f "$BINARY_PATH" ]; then
        log "Falling back to existing binary"
    else
        log "FATAL: No binary available at $BINARY_PATH"
        exit 1
    fi
}

start_x() {
    if [ -z "${DISPLAY:-}" ]; then
        # Disable kernel console blanking (HDMI signal dropout)
        setterm --blank 0 --powerdown 0 2>/dev/null || true
        echo 0 > /sys/module/kernel/parameters/consoleblank 2>/dev/null || true

        log "Starting X server..."
        Xorg :0 -nolisten tcp &
        X_PID=$!
        export DISPLAY=:0
        sleep 3
        log "X server started on :0 (PID $X_PID)"
    fi
}

start_binary() {
    start_x
    log "Starting $BINARY_PATH"
    DISPLAY=:0 MESA_GL_VERSION_OVERRIDE=3.3 "$BINARY_PATH" &
    BINARY_PID=$!
    log "Binary started with PID $BINARY_PID"
}

stop_binary() {
    if [ -n "$BINARY_PID" ] && kill -0 "$BINARY_PID" 2>/dev/null; then
        log "Stopping binary (PID $BINARY_PID)"
        kill "$BINARY_PID"
        wait "$BINARY_PID" 2>/dev/null
    fi
    BINARY_PID=""
}

cleanup() {
    stop_binary
    if [ -n "${X_PID:-}" ] && kill -0 "$X_PID" 2>/dev/null; then
        log "Stopping X server (PID $X_PID)"
        kill "$X_PID"
    fi
    rm -f "$FIFO" "$SIGNAL_FILE"
    log "Cleanup complete"
}

restart_listener() {
    mkfifo "$FIFO"
    log "Restart listener started on port $LISTEN_PORT"

    while true; do
        cat "$FIFO" | nc -l "$LISTEN_PORT" | (
            read -r request_line
            while IFS= read -r header && [ -n "$header" ] && [ "$header" != $'\r' ]; do :; done
            read -r -t 1 body || body=""

            if [[ "$request_line" == *"$RESTART_SECRET"* ]] || [[ "$body" == *"$RESTART_SECRET"* ]]; then
                printf "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nRestarting...\n" > "$FIFO"
                touch "$SIGNAL_FILE"
            else
                printf "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\nBad secret\n" > "$FIFO"
            fi
        )

        if [ -f "$SIGNAL_FILE" ]; then
            rm -f "$SIGNAL_FILE"
            log "Restart requested via HTTP"
            stop_binary
            download_latest_binary
            start_binary
        fi
    done
}

trap cleanup EXIT

download_latest_binary
start_binary
restart_listener
