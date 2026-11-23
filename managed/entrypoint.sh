#!/bin/bash
# Single-port entrypoint: configures the panel from env, then runs Caddy and
# the stock 3x-ui entrypoint side by side. If either exits, the container
# exits so the platform restarts it.
set -u

fail() { echo "[managed] ERROR: $*" >&2; exit 1; }

PROXY_MODE="${PROXY_MODE:-edge}"
PORT="${PORT:-8080}"
PANEL_PATH="${PANEL_PATH:-/panel/}"
VPN_PATH_PREFIX="${VPN_PATH_PREFIX:-/vpn}"

# Normalise: PANEL_PATH -> /x/y/ ; VPN_PATH_PREFIX -> /x/y
PANEL_PATH="/$(echo "$PANEL_PATH" | sed 's#^/*##; s#/*$##')/"
VPN_PATH_PREFIX="/$(echo "$VPN_PATH_PREFIX" | sed 's#^/*##; s#/*$##')"
PANEL_PATH_NOSLASH="${PANEL_PATH%/}"

# These values are substituted into the Caddyfile (one of them into a regex).
safe='^(/[A-Za-z0-9_-]+)+$'
[[ "$PANEL_PATH_NOSLASH" =~ $safe ]] || fail "PANEL_PATH must be a non-root path of letters, digits, '_' and '-' (got '$PANEL_PATH')"
[[ "$VPN_PATH_PREFIX" =~ $safe ]] || fail "VPN_PATH_PREFIX must be a non-root path of letters, digits, '_' and '-' (got '$VPN_PATH_PREFIX')"
case "$PANEL_PATH/" in "$VPN_PATH_PREFIX"/*) fail "PANEL_PATH must not be inside VPN_PATH_PREFIX" ;; esac
case "$VPN_PATH_PREFIX/" in "$PANEL_PATH"*) fail "VPN_PATH_PREFIX must not be inside PANEL_PATH" ;; esac

case "$PROXY_MODE" in
    edge)
        [[ "$PORT" =~ ^[0-9]+$ ]] || fail "PORT must be a number (got '$PORT')"
        ;;
    direct)
        [ -n "${DOMAIN:-}" ] || fail "PROXY_MODE=direct requires DOMAIN"
        ;;
    *) fail "PROXY_MODE must be 'edge' or 'direct' (got '$PROXY_MODE')" ;;
esac
export PORT PANEL_PATH PANEL_PATH_NOSLASH VPN_PATH_PREFIX

# The panel does not strip a proxy prefix, so its base path must equal the
# public sub-path. Bind it to loopback: only Caddy should reach it.
set -- -webBasePath "$PANEL_PATH" -listenIP 127.0.0.1
if [ -n "${PANEL_USERNAME:-}" ] && [ -n "${PANEL_PASSWORD:-}" ]; then
    set -- "$@" -username "$PANEL_USERNAME" -password "$PANEL_PASSWORD"
elif [ -n "${PANEL_USERNAME:-}${PANEL_PASSWORD:-}" ]; then
    fail "set both PANEL_USERNAME and PANEL_PASSWORD, or neither"
fi
/app/x-ui setting "$@" >/dev/null || fail "could not apply panel settings"

mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
echo "[managed] mode=$PROXY_MODE panel=$PANEL_PATH vpn=$VPN_PATH_PREFIX/<10000-10999>"

caddy run --config "/app/managed/Caddyfile.$PROXY_MODE" --adapter caddyfile &
caddy_pid=$!
/app/DockerEntrypoint.sh &
xui_pid=$!

stop() { kill -TERM "$caddy_pid" "$xui_pid" 2>/dev/null; }
trap 'stop; wait; exit 0' TERM INT

wait -n "$caddy_pid" "$xui_pid"
code=$?
echo "[managed] a process exited (status $code); stopping container" >&2
stop
wait
[ "$code" -ne 0 ] || code=1
exit "$code"
