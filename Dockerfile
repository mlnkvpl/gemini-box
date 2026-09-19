FROM node:20-slim

# Install standard utilities that code agents rely on
RUN apt-get update && apt-get install -y git curl ca-certificates && rm -rf /var/lib/apt/lists/*

# Install Gemini CLI and official Chrome DevTools MCP server globally
RUN npm install -g @google/gemini-cli chrome-devtools-mcp

WORKDIR /workspace

ENTRYPOINT ["gemini"]
