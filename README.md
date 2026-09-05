# gMCP

A self-hosted MCP (Model Context Protocol) server that gives an LLM conversational, diagnostic access to **your own** Google marketing/analytics data — Google Tag Manager, GA4, Search Console, BigQuery, PageSpeed Insights, AdSense, Google Ads, and Google Business Profile.

Self-hosted by design: your Google OAuth tokens and data stay on infrastructure you control. There's no third-party service sitting between your Google account and the LLM.

This repo ships two install paths. Pick whichever fits how you already work:

| | Windows local install | Server install |
|---|---|---|
| Best for | Claude Desktop / Claude Code on your own PC | A shared chat UI (LibreChat) reachable from anywhere, or any other remote-MCP-capable client |
| Your own OS | Windows only | **Any** — macOS, Linux, Windows. Nothing is installed locally |
| Also requires | — | A Linux host with Docker (a $6–12/mo droplet works fine) and a subdomain you control |
| Where your Google tokens live | Your PC only | The server you deploy to |
| Who does the Google consent | The wizard on your PC | The server, in your browser |

Both paths connect the same underlying services — pick as many or as few Google products as you've actually got access to; gMCP only exposes tools for the ones you connect.

## Windows local install (Claude Desktop)

1. Download `gmcp.mcpb` from the [Releases page](../../releases/latest).
2. In Claude Desktop, open Settings → Extensions and drag `gmcp.mcpb` onto the install screen (or double-click the file).
3. You'll be prompted for a Google OAuth Client ID/Secret. Create one at the [Google Cloud Console](https://console.cloud.google.com/apis/credentials) (type: "Web application"), then enable whichever Google APIs you want to use (GTM, GA4, Search Console, etc.) in that same Cloud project.
4. Restart Claude Desktop. gMCP will walk you through connecting each service (a browser tab opens for Google's consent screen per service) and choosing read-only vs. read/write access.

Using a different MCP client (Claude Code, or anything else that supports local/stdio MCP servers)? Point it at the `gmcp.exe` bundled inside the extension, and run `gmcp setup` once from a terminal to do the same service/OAuth walkthrough via a local browser wizard.

Mac/Linux users: there's no pre-built binary for your platform yet — use the server install below, which needs nothing installed on your own machine at all.

## Server install (Docker + LibreChat, any Linux host)

This deploys gMCP alongside [LibreChat](https://www.librechat.ai/) (a full chat UI) and [Caddy](https://caddyserver.com/) (automatic HTTPS), all behind one subdomain you point at the server.

**Before you start, you need:**
- A Linux server with Docker + Docker Compose installed (a DigitalOcean droplet, or any other VPS — 4GB+ RAM once a few services are running), reachable over SSH. Root or an ordinary user with Docker access both work — the installer deploys into that user's home directory and never needs `sudo`.
- A subdomain's DNS **A record already pointing at that server's IP** (Caddy needs this to complete its Let's Encrypt certificate challenge).
- An [OpenRouter](https://openrouter.ai/) API key (this is what powers the chat model — separate from your Google credentials). Before deploying, set the account-wide training opt-out at [openrouter.ai/settings/privacy](https://openrouter.ai/settings/privacy) — the installer bakes Zero Data Retention into every request automatically, but that one opt-out toggle is manual.
- A Google Cloud project with a **"Web application"** OAuth client (Client ID + Secret), and the APIs you want **enabled in that project** — they're each separate: Tag Manager API, Google Analytics Admin API *and* Google Analytics Data API (GA4 needs both), Search Console API, BigQuery API, AdSense Management API, PageSpeed Insights API.
- On your own machine, just `bash`, `ssh` and `curl` — no gMCP binary, no Rust, no Docker. (On Windows, Git Bash or WSL.)

> While your OAuth consent screen is in **Testing** mode, only accounts listed as test users can authorize, and Google expires refresh tokens after 7 days — so gMCP will stop working weekly until you publish the app. For a self-hosted tool used only by you, adding yourself as a test user is fine short-term, but publishing avoids the weekly re-consent.

**Steps:**

1. In the [Google Cloud Console](https://console.cloud.google.com/apis/credentials), open your "Web application" OAuth client and add this **Authorized redirect URI** (Google matches it exactly):
   ```
   https://<your-subdomain>/oauth/callback
   ```
2. Clone or download this repo, and from the `server/` folder, run:
   ```
   ./install.sh
   ```
3. It'll ask for: your server's SSH address, your subdomain, an email for Let's Encrypt, your OpenRouter key, your Google OAuth Client ID/Secret, and the login you want for the chat UI. It writes the server's configuration, starts the stack, and creates your account.
4. Once Caddy finishes obtaining its certificate (check with `docker compose logs -f caddy` on the server), your chat UI is live at `https://<your-subdomain>`. Sign in with the account the installer created.
5. Connect each Google service you want. The installer prints these commands filled in, including your bearer token (it's gMCP's own token, generated during install and stored as `GMCP_HTTP_TOKEN` in the server's `.env`). Ask the server for a consent URL, open it in any browser, approve — tokens are minted and stored **on the server**, nothing runs on your machine.
   ```
   curl -s -X POST https://<your-subdomain>/oauth/start \
     -H 'Authorization: Bearer <your GMCP_HTTP_TOKEN>' \
     -H 'Content-Type: application/json' \
     -d '{"service":"ga4","access":"readonly"}'
   ```
   Valid services: `gtm`, `ga4`, `search_console`, `bigquery`, `pagespeed`, `adsense`, `google_ads`, `gbp`. Use `"access":"readwrite"` only where you want write tools (currently only `gtm` has any). Then restart gMCP so it registers the new tools:
   ```
   ssh you@<your-server> "cd ~/gmcp-server && docker compose restart gmcp"
   ```

> If you already ran `gmcp setup` on a Windows machine, the installer detects `~/.gmcp` and copies those authorizations up instead, and you can skip step 5.

> **Public signup is deliberately disabled.** This server holds *your* Google refresh tokens, and every LibreChat user on it shares a single gMCP credential — so anyone who could register would get read access to your analytics data, plus whatever write access you granted. Add more people deliberately instead:
> ```
> ssh you@your-server "cd ~/gmcp-server && docker compose exec api npm run create-user"
> ```
5. In LibreChat, create an **Agent** (not just a plain chat) and attach gMCP's tools to it — that's what makes the connected Google services available to the model.

gMCP's own `/mcp` endpoint is also reachable directly at `https://<your-subdomain>/mcp` (bearer-token protected — the token is generated automatically and stored in `~/.gmcp/http_token.json` on your machine), so any other MCP-capable client can connect to your server too, not just LibreChat.

### Adding a service later

Repeat step 5 for the service you want, then `docker compose restart gmcp`. No reinstall, and nothing needed on your own machine.

## Read-only vs. read/write

Every service can be connected as **read-only** or **read/write**, chosen per-service when you connect it. Read/write access uses genuinely separate OAuth scopes — a read-only connection is structurally incapable of making write calls. Any write/mutating action (e.g. pausing a GTM tag) always requires a two-step propose → confirm flow: the model first calls a `propose_*` tool that only returns a plain-language summary and a short-lived confirmation token, then a separate `apply_*` tool call (with that token) actually makes the change. No tool can mutate anything in a single call.

(Google Ads and Google Business Profile are the two exceptions — Google only offers one combined OAuth scope for each, so "read-only" for those two is enforced in code rather than by scope.)
