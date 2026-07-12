#!/usr/bin/env bash

set -euo pipefail

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="WDS"
BUNDLE_ID="com.heznpc.WDS"
APP_BUNDLE="$ROOT_DIR/dist/WDS.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/WDS"

stop_running_app() {
    if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
        return
    fi

    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 \
        || pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 \
        || true

    for _ in {1..20}; do
        if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            return
        fi
        sleep 0.05
    done
    pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
}

launch_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
    run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
        ;;
    *)
        echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
        exit 2
        ;;
esac

stop_running_app
"$ROOT_DIR/scripts/build-wds-app.sh"

case "$MODE" in
    run)
        launch_app
        ;;
    --debug|debug)
        lldb -- "$APP_BINARY"
        ;;
    --logs|logs)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
        ;;
    --telemetry|telemetry)
        launch_app
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    --verify|verify)
        launch_app
        for _ in {1..40}; do
            if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
                exit 0
            fi
            sleep 0.05
        done
        echo "$APP_NAME did not remain running after launch" >&2
        exit 1
        ;;
esac
