#!/usr/bin/env bash

# Base directory for the gemini sandbox setup
GEMINI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Read CLI_NAME from .env (fallback to gemini-box)
if [ -f "$GEMINI_DIR/.env" ]; then
  CUSTOM_CLI=$(grep -E '^CLI_NAME=' "$GEMINI_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ')
fi
CMD="${CUSTOM_CLI:-gemini-box}"

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
