# Gemini-Box: Setup & Reproduction Instructions

Full from-scratch setup steps for gemini-box — prerequisites, the exact file contents to
place at `~/gemini/` (the actual deployment directory; see root README.md's Directory
Structure section), firewall config, and the build/install commands. For what this is and
day-to-day usage, see [`../README.md`](../README.md).

---

## 1. Prerequisites

* Docker and Docker Compose v2 (`docker compose`) installed on Ubuntu.
* `socat` and Google Chrome installed on your host system:
```bash
sudo apt update && sudo apt install -y socat google-chrome-stable
```


* A Gemini API key from [Google AI Studio](https://aistudio.google.com).
* Workspace directory:
```bash
mkdir -p ~/workdir
```



---
## 2. File Configurations

Create the setup directory:

```bash
mkdir -p ~/gemini/.config ~/gemini/scripts
cd ~/gemini
chmod 700 .config
```

### `Dockerfile`

```dockerfile
FROM node:20-slim

# Install standard utilities that code agents rely on.
# jq/ripgrep/shellcheck/python3+python3-yaml: diagnostic/verification tools.
# libnss3-tools: mkcert needs it to cover Firefox's own trust store too.
# gnupg: needed for the PHP apt repo signing key below.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl ca-certificates procps \
        jq ripgrep shellcheck python3 python3-yaml libnss3-tools gnupg \
    && rm -rf /var/lib/apt/lists/*

# PHP 8.3 CLI + Composer — matches this workspace's actual runtime version,
# so `php -l`, `composer validate`, etc. run against the same PHP the real
# app deploys on, not whatever Debian's default happens to ship.
RUN curl -sSL https://packages.sury.org/php/apt.gpg -o /etc/apt/trusted.gpg.d/php.gpg \
    && . /etc/os-release \
    && echo "deb https://packages.sury.org/php/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        php8.3-cli php8.3-mbstring php8.3-xml php8.3-curl php8.3-sqlite3 php8.3-pgsql \
    && rm -rf /var/lib/apt/lists/* \
    && curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# mkcert — for exercising any locally-trusted-TLS setup in the workspace
# instead of just reading the script and trusting it.
RUN curl -sSL "https://dl.filippo.io/mkcert/latest?for=linux/amd64" -o /usr/local/bin/mkcert \
    && chmod +x /usr/local/bin/mkcert

# --- Docker CLI (client only — Docker-outside-of-Docker) ---
# No daemon runs in this container. `docker`/`docker compose` here talk to
# docker-socket-proxy (see docker-compose.yml) over DOCKER_HOST, not to a raw
# mounted socket and not to a nested dockerd. The proxy holds the real
# /var/run/docker.sock and exposes only a scoped subset of the Docker API —
# see docker-compose.yml for the exact grants.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI and official Chrome DevTools MCP server globally
RUN npm install -g @google/gemini-cli chrome-devtools-mcp

# Fix: the entrypoint runs as the `node` user at runtime but this global
# install happens as root at build time — this breaks the CLI's
# self-updater with a permissions error if it self-updates the same way.
# Hand the install tree to `node` so it can update itself.
RUN chown -R node:node /usr/local/lib/node_modules /usr/local/bin

# Fallback only — docker-compose.yml's `working_dir:` overrides this at
# runtime to the host-mirrored path (see that file for why).
WORKDIR /workspace

ENTRYPOINT ["gemini"]
```

### `docker-compose.yml`

```yaml
services:
  # Docker-outside-of-Docker access, scoped. Holds the real host socket
  # itself; `gemini` never sees it directly — it only talks to this proxy
  # over DOCKER_HOST. Grants write access to containers/images/networks/
  # volumes/build/exec; everything else (swarm, secrets, plugins, system,
  # nodes, services, tasks, configs) stays at the proxy's default-deny.
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: gemini-box-docker-proxy
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - CONTAINERS=1
      - IMAGES=1
      - NETWORKS=1
      - VOLUMES=1
      - BUILD=1
      - EXEC=1
      - POST=1

  gemini:
    build: .
    user: "${UID:-1000}:${GID:-1000}"
    # Must match the host-side volume path exactly — see the note in
    # "Architecture & Security Boundary" above (Host-mirrored workspace path).
    # cli.sh exports HOST_WORKDIR="$HOME/workdir" before every invocation.
    working_dir: ${HOST_WORKDIR}
    stdin_open: true
    tty: true
    depends_on:
      - docker-socket-proxy
    extra_hosts:
      - "host.docker.internal:172.17.0.1"
    volumes:
      - ${HOST_WORKDIR}:${HOST_WORKDIR}
      - ./.config:/home/node/.gemini
    environment:
      - GEMINI_API_KEY=${GEMINI_API_KEY}
      - CHROME_CDP_URL=http://172.17.0.1:9223
      - DOCKER_HOST=tcp://docker-socket-proxy:2375
```

### `.config/settings.json`

Configures the agent to use API key authentication and enables the slim browser toolset to minimize token consumption:

```json
{
  "selectedAuthType": "gemini-api-key",
  "mcpServers": {
    "chrome-browser": {
      "command": "chrome-devtools-mcp",
      "args": [
        "--browser-url=http://172.17.0.1:9223",
        "--slim"
      ]
    }
  }
}

```

### `.env`

```ini
GEMINI_API_KEY="your-gemini-api-key-here"
CLI_NAME="gemini-box"

```

### `cli.sh`

```bash
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
```

### `scripts/help.sh`

Sourced by `cli.sh` for the `help`/`--help`/`-h` command:

```bash
#!/usr/bin/env bash
#
# Help text for the gemini-box CLI. Sourced by cli.sh; relies on $CMD
# (resolved there from CLI_NAME in .env, default "gemini-box").
#

show_help()
{
  printf '\n%s — sandboxed Gemini CLI\n\n' "${CMD}"
  printf 'Usage: %s [args...]   Launch Gemini CLI — interactive with no args, or pass\n' "${CMD}"
  printf '                          flags/prompts straight through\n\n'

  printf 'Container lifecycle:\n'
  printf '  %-12s %s\n' "ps" "Show status (mainly docker-socket-proxy — gemini itself"
  printf '  %-12s %s\n' ""   "only exists for the duration of a run)"
  printf '  %-12s %s\n' "stop" "Stop running containers without removing them"
  printf '  %-12s %s\n' "down" "Stop AND remove everything (docker-socket-proxy + its"
  printf '  %-12s %s\n' ""     "network) — the proxy otherwise keeps running in the"
  printf '  %-12s %s\n' ""     "background between sessions"
  printf '  %-12s %s\n\n' "logs [service]" "Follow logs"

  printf 'Setup:\n'
  printf '  %-12s %s\n' "build" "Build/rebuild the Docker image"
  printf '  %-12s %s\n' "chrome" "Launch host Chrome + socat bridge for browser automation"
  printf '  %-12s %s\n' "install" "Install the global \"${CMD}\" command + ~/.bashrc hook"
  printf '  %-12s %s\n' "uninstall" "Remove that hook"
  printf '  %-12s %s\n\n' "help" "Show this help"

  printf 'See README.md for the full setup/troubleshooting guide.\n\n'
}
```

Make the script executable:

```bash
chmod +x ~/gemini/cli.sh
```

---

## 3. Firewall Configuration (Ubuntu UFW)

Allow the Docker bridge subnet to access the forwarder port:

```bash
sudo ufw allow in on docker0 to any port 9223 proto tcp
```

---

## 4. Build & Install Hook

1. Build the Docker container image:
```bash
~/gemini/cli.sh build
```


2. Register the terminal alias into `~/.bashrc`:
```bash
~/gemini/cli.sh install
source ~/.bashrc
```

