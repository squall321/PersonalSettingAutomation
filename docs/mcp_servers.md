MCP Servers — format and examples

Purpose
- Describe the expected server configuration format used by scripts in this repository.
- Provide examples for HTTP and gRPC-style MCP servers and guidance for authentication and TLS.

Fields
- `type` (string) — "http" or "grpc". Determines transport and client used.
- `url` (string) — Full endpoint URL including scheme and path (e.g. "http://host:8088/mcp-gw/mcp").
- `headers` (object) — Optional map of HTTP headers to include on requests (useful for Authorization Bearer tokens).
- `tls` (object, optional) — TLS options when connecting to servers that require custom CA or client certs.
  - `ca_path` (string) — Path to PEM CA bundle to trust.
  - `client_cert` (string) — Path to client certificate (.pem/.crt).
  - `client_key` (string) — Path to client private key.
- `notes` (string, optional) — Free-form notes for administrators.

Example (HTTP server with Bearer token)

```json
{
  "mcpServers": {
    "hwax": {
      "type": "http",
      "url": "http://110.15.177.120:8088/mcp-gw/mcp",
      "headers": {
        "Authorization": "Bearer <TOKEN_HERE>",
        "Accept": "application/json"
      },
      "notes": "Primary HWAX MCP gateway"
    }
  }
}
```

Example (HTTPS with custom CA and client cert)

```json
{
  "mcpServers": {
    "secure-gw": {
      "type": "http",
      "url": "https://secure.example.com/mcp",
      "tls": {
        "ca_path": "/etc/ssl/certs/corp-ca.pem",
        "client_cert": "/home/user/.certs/client.crt",
        "client_key": "/home/user/.certs/client.key"
      }
    }
  }
}
```

Usage notes
- Store tokens separately from repository if they are secrets. Use environment variables or an OS keyring. The repo `mcp_servers.json` is convenient for local testing but avoid committing real secrets.
- For HTTP servers, include `Accept: application/json` and `Content-Type: application/json` in headers when calling JSON-RPC.
- For gRPC servers, a different client will be required; include `type": "grpc"` and specify `url` as `host:port`.

Client script
- Consider adding a small script `scripts/mcp_call.sh` that reads `mcp_servers.json`, picks a server key, and issues a JSON-RPC call using `curl` while honoring `tls` fields (e.g., `--cacert` and `--cert/--key`).

Security
- Never commit long-lived tokens. Rotate tokens periodically.
- Keep `mcp_servers.json` with placeholder tokens in repo; use environment or CI secret managers for real tokens.
