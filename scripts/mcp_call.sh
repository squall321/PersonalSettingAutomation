#!/usr/bin/env bash
# Simple MCP JSON-RPC caller that reads `mcp_servers.json` and issues an RPC.
# Usage: scripts/mcp_call.sh <server-key> <method> [params-json]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
CONFIG_FILE="${ROOT_DIR}/mcp_servers.json"

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <server-key> <method> [params-json]"
  exit 2
fi

KEY="$1"; METHOD="$2"; PARAMS="${3:-{}}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config not found: $CONFIG_FILE" >&2; exit 1
fi

# Extract server entry via jq
if ! command -v jq &>/dev/null; then
  echo "Please install 'jq' to use this script" >&2; exit 1
fi

SERVER_JSON=$(jq -r --arg k "$KEY" '.mcpServers[$k] // empty' "$CONFIG_FILE")
if [[ -z "$SERVER_JSON" || "$SERVER_JSON" == "null" ]]; then
  echo "Server key not found in $CONFIG_FILE: $KEY" >&2; exit 1
fi

URL=$(jq -r '.url // empty' <<< "$SERVER_JSON")
TYPE=$(jq -r '.type // "http"' <<< "$SERVER_JSON")
HEADERS=$(jq -r '.headers // {}' <<< "$SERVER_JSON")

if [[ -z "$URL" ]]; then
  echo "No URL for server $KEY" >&2; exit 1
fi

# Build curl header args
CURL_HDRS=()
for name in $(jq -r 'keys[]' <<< "$HEADERS"); do
  val=$(jq -r --arg n "$name" '.[$n]' <<< "$HEADERS")
  CURL_HDRS+=( -H "$name: $val" )
done

# Basic JSON-RPC body
# Ensure PARAMS is valid JSON; fail early if not
if ! echo "$PARAMS" | jq -e . >/dev/null 2>&1; then
  echo "Invalid JSON for params: $PARAMS" >&2
  exit 2
fi

# Build JSON-RPC body safely without complex jq --argjson escaping
BODY=$(printf '{"jsonrpc":"2.0","method":"%s","params":%s,"id":"cli"}' "$METHOD" "$PARAMS")

if [[ "$TYPE" != "http" ]]; then
  echo "Only http type is supported by this script" >&2; exit 1
fi

# Execute
curl -s -i -X POST "$URL" \
  -H 'Content-Type: application/json' \
  "${CURL_HDRS[@]}" \
  -d "$BODY"
