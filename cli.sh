#!/usr/bin/env bash

# Base directory for the gemini sandbox setup
GEMINI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read CLI_NAME from .env (fallback to gemini-box)
if [ -f "$GEMINI_DIR/.env" ]; then
  CUSTOM_CLI=$(grep -E '^CLI_NAME=' "$GEMINI_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ')
fi
CMD="${CUSTOM_CLI:-gemini-box}"

source "$GEMINI_DIR/scripts/help.sh"

INSTALL_LINE="[ -f \"$GEMINI_DIR/cli.sh\" ] && source \"$GEMINI_DIR/cli.sh\" env"

case "$1" in
  # 1. Install shortcut into ~/.bashrc
  install)
    if grep -Fxq "$INSTALL_LINE" "$HOME/.bashrc"; then
      echo "[✓] Shell hook already installed in ~/.bashrc"
    else
      echo "" >> "$HOME/.bashrc"
      echo "# Gemini CLI sandbox hook" >> "$HOME/.bashrc"
      echo "$INSTALL_LINE" >> "$HOME/.bashrc"
      echo "[✓] Added hook to ~/.bashrc. Run: source ~/.bashrc"
    fi
    ;;

  # 2. Remove shortcut from ~/.bashrc
  uninstall)
    sed -i "\|$INSTALL_LINE|d" "$HOME/.bashrc"
    echo "[✓] Removed hook from ~/.bashrc. Restart your shell."
    ;;

  # 3. Build/rebuild the docker container
  build)
    echo "Building Gemini container..."
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" build
    ;;

  # Show status of this compose file's services. Note docker-socket-proxy is
  # normally the only thing "up" here — `gemini` only exists for the
  # duration of a `run --rm` invocation (see the default case below), so it
  # won't show as running between sessions even though the proxy does.
  ps)
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" ps
    ;;

  # Stop running services without removing them (mainly docker-socket-proxy).
  stop)
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" stop
    ;;

  # Stop AND remove everything this compose file owns (docker-socket-proxy +
  # its network). docker-socket-proxy uses `restart: unless-stopped` and is
  # only ever *started* via `depends_on` on the `gemini` service — `run --rm`
  # removes the `gemini` container on exit but never touches its
  # dependencies, so the proxy otherwise keeps running indefinitely in the
  # background even with no gemini session active. This is the only way to
  # actually shut it down. Same behavior as claude-box — see its cli.sh.
  down)
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" down
    ;;

  logs)
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" logs -f "${@:2}"
    ;;

  help|--help|-h)
    show_help
    ;;

  # 3. Sourced by ~/.bashrc to export the dynamic shell function
  env)
    eval "
    ${CMD}() {
      case \"\$1\" in
        chrome)
          \"$GEMINI_DIR/cli.sh\" chrome
          ;;
        build)
          \"$GEMINI_DIR/cli.sh\" build
          ;;
        ps)
          \"$GEMINI_DIR/cli.sh\" ps
          ;;
        stop)
          \"$GEMINI_DIR/cli.sh\" stop
          ;;
        down)
          \"$GEMINI_DIR/cli.sh\" down
          ;;
        logs)
          \"$GEMINI_DIR/cli.sh\" logs \"\${@:2}\"
          ;;
        help|--help|-h)
          \"$GEMINI_DIR/cli.sh\" help
          ;;
        *)
          HOST_WORKDIR=\"\$HOME/workdir\" GID=\$(id -g) docker compose -f \"$GEMINI_DIR/docker-compose.yml\" run --rm gemini \"\$@\"
          ;;
      esac
    }
    "
    ;;

  # 4. Launch isolated Chrome instance with remote debugging enabled
chrome)
    echo "Launching Chrome with remote debugging..."
    mkdir -p /tmp/chrome-agent-profile
    google-chrome \
      --remote-debugging-port=9222 \
      --user-data-dir=/tmp/chrome-agent-profile \
      --ignore-certificate-errors \
      --no-first-run \
      --no-default-browser-check > /dev/null 2>&1 &

    # Kill any previous forwarder and forward docker0 traffic to 127.0.0.1:9222
    pkill -f "socat.*9223" || true
    sleep 1
    socat TCP-LISTEN:9223,fork,bind=0.0.0.0 TCP:127.0.0.1:9222 > /dev/null 2>&1 &
    echo "[✓] Chrome running on 9222, exposed to Docker via socat on port 9223 (PID: $!)."
    ;;

  # 6. Default/Run: direct invocation without sourcing
  *)
    HOST_WORKDIR="$HOME/workdir" GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" run --rm gemini "$@"
    ;;
esac
