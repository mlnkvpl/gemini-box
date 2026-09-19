
# Gemini-Box: Sandboxed Gemini CLI + Browser Automation

A secure, isolated Docker container setup for running Google's official Gemini CLI (`@google/gemini-cli`) paired with live host browser automation via the Chrome DevTools Model Context Protocol (`chrome-devtools-mcp`).

It isolates the agent strictly inside your `~/workdir` projects, shields your host home directory (SSH keys, shell dotfiles, personal credentials), prevents root file-permission issues, and bridges safely to your host's Google Chrome instance for autonomous web tasks.

---

## Architecture & Security Boundary

* **Host Filesystem Isolation:** The agent only accesses `~/workdir` (mounted to `/workspace`). It cannot read host paths such as `~/.ssh`, `~/.aws`, or `~/.bashrc`.
* **Clean User Permissions:** Runs mapped to your host's non-root `UID:GID`, ensuring files created or modified by the agent remain editable on your host.
* **Persistent Configuration:** Authentication tokens, project history, and MCP server configurations persist in `~/gemini/.config` (mapped to `/home/node/.gemini`).
* **Safe Host Browser Bridge:** Controls your host Chrome instance over the Chrome DevTools Protocol (CDP). A lightweight `socat` bridge forwards container traffic (`172.17.0.1:9223`) to Chrome's local loopback listener (`127.0.0.1:9222`), bypassing Chrome's DNS-rebinding security checks while keeping the container sandboxed.

---

## Directory Structure

```text
~/gemini/
├── .config/
│   └── settings.json    # MCP server configuration & auth type
├── .env                 # API Key and CLI shortcut name
├── cli.sh               # Shell installer, Chrome launcher, builder, and runner
├── docker-compose.yml   # Bridge network, user mapping, volume mounts, extra_hosts
├── Dockerfile           # Node 20-slim + Gemini CLI + chrome-devtools-mcp
└── README.md            # Documentation
```

---

## Setup & Reproduction Steps

### 1. Prerequisites

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
### 2. File Configurations

Create the setup directory:

```bash
mkdir -p ~/gemini/.config
cd ~/gemini
chmod 700 .config
```

#### `Dockerfile`

```dockerfile
FROM node:20-slim

# Install system utilities commonly needed by agent tools
RUN apt-get update && apt-get install -y git curl ca-certificates procps && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI and official Chrome DevTools MCP server globally
RUN npm install -g @google/gemini-cli chrome-devtools-mcp

WORKDIR /workspace

ENTRYPOINT ["gemini"]
```

#### `docker-compose.yml`

```yaml
services:
  gemini:
    build: .
    user: "${UID:-1000}:${GID:-1000}"
    working_dir: /workspace
    stdin_open: true
    tty: true
    extra_hosts:
      - "host.docker.internal:172.17.0.1"
    volumes:
      - ~/workdir:/workspace
      - ./.config:/home/node/.gemini
    environment:
      - GEMINI_API_KEY=${GEMINI_API_KEY}
      - CHROME_CDP_URL=[http://172.17.0.1:9223](http://172.17.0.1:9223)

```

#### `.config/settings.json`

Configures the agent to use API key authentication and enables the slim browser toolset to minimize token consumption:

```json
{
  "selectedAuthType": "gemini-api-key",
  "mcpServers": {
    "chrome-browser": {
      "command": "chrome-devtools-mcp",
      "args": [
        "--browser-url=[http://172.17.0.1:9223](http://172.17.0.1:9223)",
        "--slim"
      ]
    }
  }
}

```

#### `.env`

```ini
GEMINI_API_KEY="your-gemini-api-key-here"
CLI_NAME="gemini-box"

```

#### `cli.sh`

```bash
#!/usr/bin/env bash

GEMINI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$GEMINI_DIR/.env" ]; then
  CUSTOM_CLI=$(grep -E '^CLI_NAME=' "$GEMINI_DIR/.env" | cut -d '=' -f2- | tr -d '"'\'' ')
fi
CMD="${CUSTOM_CLI:-gemini-box}"

INSTALL_LINE="[ -f \"$GEMINI_DIR/cli.sh\" ] && source \"$GEMINI_DIR/cli.sh\" env"

case "$1" in
  install)
    if grep -Fxq "$INSTALL_LINE" "$HOME/.bashrc"; then
      echo "[✓] Hook already present in ~/.bashrc"
    else
      echo "" >> "$HOME/.bashrc"
      echo "# Gemini CLI sandbox hook" >> "$HOME/.bashrc"
      echo "$INSTALL_LINE" >> "$HOME/.bashrc"
      echo "[✓] Installed hook into ~/.bashrc. Run: source ~/.bashrc"
    fi
    ;;

  uninstall)
    sed -i "\|$INSTALL_LINE|d" "$HOME/.bashrc"
    echo "[✓] Removed hook from ~/.bashrc."
    ;;

  build)
    echo "Building Gemini container..."
    GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" build
    ;;

  # Launch isolated Chrome instance and socat forwarder
  chrome)
    echo "Launching host Chrome with remote debugging on port 9222..."
    mkdir -p /tmp/chrome-agent-profile
    google-chrome \
      --remote-debugging-port=9222 \
      --user-data-dir=/tmp/chrome-agent-profile \
      --no-first-run \
      --no-default-browser-check > /dev/null 2>&1 &

    # Forward docker0 bridge traffic (port 9223) to host localhost (port 9222)
    pkill -f "socat.*9223" || true
    sleep 1
    socat TCP-LISTEN:9223,fork,bind=0.0.0.0 TCP:127.0.0.1:9222 > /dev/null 2>&1 &
    echo "[✓] Chrome running on 9222, bridged to Docker on 172.17.0.1:9223."
    ;;

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
          GID=\$(id -g) docker compose -f \"$GEMINI_DIR/docker-compose.yml\" run --rm gemini \"\$@\"
          ;;
      esac
    }
    "
    ;;

  *)
    GID=$(id -g) docker compose -f "$GEMINI_DIR/docker-compose.yml" run --rm gemini "$@"
    ;;
esac

```

Make the script executable:

```bash
chmod +x ~/gemini/cli.sh
```

---

### 3. Firewall Configuration (Ubuntu UFW)

Allow the Docker bridge subnet to access the forwarder port:

```bash
sudo ufw allow in on docker0 to any port 9223 proto tcp
```

---

### 4. Build & Install Hook

1. Build the Docker container image:
```bash
~/gemini/cli.sh build
```


2. Register the terminal alias into `~/.bashrc`:
```bash
~/gemini/cli.sh install
source ~/.bashrc
```


---

## Workflow & Usage

### 1. Start the Host Browser Bridge

Before initiating browser automation, run the Chrome launcher on your host:

```bash
~/gemini/cli.sh chrome
```

### 2. Launch Gemini CLI

Start an interactive agent session from any working directory:

```bash
gemini-box
```

### 3. Model Recommendation & Quotas

For tool-calling and web automation on the free tier, use Flash models to avoid hitting strict daily limits:

```text
/model gemini-3.5-flash
```

### 4. Example Browser Prompts

* "Navigate to google.com and search for the latest news on Linux kernel releases."
* "Navigate to https://news.ycombinator.com and extract the titles and URLs of the top 5 submissions."

---

## Troubleshooting

* **Permission denied (`EACCES: /home/node/.gemini/...`):**
If files in `.config` were created as `root`, reset ownership to your current host user:
```bash
sudo chown -R $(id -u):$(id -g) ~/gemini/.config
chmod 700 ~/gemini/.config
```


* **Chrome connection hangs or times out:**
Verify that both Chrome and the `socat` bridge are listening:
```bash
ss -tulpn | grep -E '9222|9223'
```


Test the endpoint directly from inside the container:
```bash
docker compose -f ~/gemini/docker-compose.yml run --rm --entrypoint curl gemini -m 3 -s [http://172.17.0.1:9223/json/version](http://172.17.0.1:9223/json/version)
```


* **`Host header is specified and is not an IP address or localhost`:**
Ensure `settings.json` points directly to `http://172.17.0.1:9223` instead of domain hostnames like `host.docker.internal` to prevent Chrome's internal DNS-rebinding security rejection.
