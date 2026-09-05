# gMCP

A self-hosted MCP (Model Context Protocol) server that gives an LLM conversational, diagnostic access to **your own** Google marketing and analytics data: Google Tag Manager, GA4, Search Console, BigQuery, PageSpeed Insights, AdSense, Google Ads, and Google Business Profile.

Self-hosted by design: your Google OAuth tokens and data stay on infrastructure you control. There's no third-party service sitting between your Google account and the LLM.

This repo ships two install paths. Pick whichever fits how you already work:

| | Windows local install | Server install |
|---|---|---|
| Best for | Claude Desktop / Claude Code on your own PC | A shared chat UI (LibreChat) reachable from anywhere, or any other remote-MCP-capable client |
| Your own OS | Windows only | **Any**: macOS, Linux, Windows. Nothing is installed locally |
| Also requires | Nothing | A Linux host with Docker (a 2GB droplet is enough) and a subdomain you control |
| Where your Google tokens live | Your PC only | The server you deploy to |
| Who does the Google consent | The wizard on your PC | The server, in your browser |

Both paths connect the same underlying services. Pick as many or as few Google products as you've actually got access to; gMCP only exposes tools for the ones you connect.

## Windows local install (Claude Desktop)

1. Download `gmcp.mcpb` from the [Releases page](../../releases/latest).
2. In Claude Desktop, open Settings then Extensions, and drag `gmcp.mcpb` onto the install screen (or double-click the file).
3. You'll be prompted for a Google OAuth Client ID and Secret. Create one at the [Google Cloud Console](https://console.cloud.google.com/apis/credentials) (type: "Web application"), then enable whichever Google APIs you want to use (GTM, GA4, Search Console, and so on) in that same Cloud project.
4. Restart Claude Desktop. gMCP will walk you through connecting each service (a browser tab opens for Google's consent screen per service) and choosing read-only or read/write access.

Using a different MCP client (Claude Code, or anything else that supports local/stdio MCP servers)? Point it at the `gmcp.exe` bundled inside the extension, and run `gmcp setup` once from a terminal to do the same service and OAuth walkthrough via a local browser wizard.

Mac and Linux users: there's no pre-built binary for your platform yet. Use the server install below, which needs nothing installed on your own machine at all.

## Server install (Docker + LibreChat, any Linux host)

This deploys gMCP alongside [LibreChat](https://www.librechat.ai/) (a full chat UI) and [Caddy](https://caddyserver.com/) (automatic HTTPS), all behind one subdomain you point at the server.

**Before you start, you need:**
- A Linux server with Docker and Docker Compose installed (a DigitalOcean droplet, or any other VPS), reachable over SSH. 2GB RAM is enough: the full eight-container stack was measured using about 1GB on a stock 2GB droplet, with no swap. Root or an ordinary user with Docker access both work, since the installer deploys into that user's home directory and never needs `sudo`.
- A subdomain's DNS **A record already pointing at that server's IP**. Caddy needs this to complete its Let's Encrypt certificate challenge.
- An [OpenRouter](https://openrouter.ai/) API key, which is what powers the chat model and is separate from your Google credentials. Before deploying, set the account-wide training opt-out at [openrouter.ai/settings/privacy](https://openrouter.ai/settings/privacy). The installer bakes Zero Data Retention into every request automatically, but that one opt-out toggle is manual.
- A Google Cloud project with a **"Web application"** OAuth client (Client ID and Secret), and the APIs you want **enabled in that project**. They're each separate: Tag Manager API, Google Analytics Admin API *and* Google Analytics Data API (GA4 needs both), Search Console API, BigQuery API, AdSense Management API, PageSpeed Insights API.
- On your own machine, just `bash`, `ssh` and `curl`. No gMCP binary, no Rust, no Docker. (On Windows, Git Bash or WSL.)

> While your OAuth consent screen is in **Testing** mode, only accounts listed as test users can authorize, and Google expires refresh tokens after 7 days, so gMCP will stop working weekly until you publish the app. For a self-hosted tool used only by you, adding yourself as a test user is fine short-term, but publishing avoids the weekly re-consent.

**Steps:**

1. In the [Google Cloud Console](https://console.cloud.google.com/apis/credentials), open your "Web application" OAuth client and add this **Authorized redirect URI** (Google matches it exactly):
   ```
   https://<your-subdomain>/oauth/callback
   ```
2. Clone or download this repo, and from the `server/` folder, run:
   ```
   ./install.sh
   ```
3. It'll ask for: your server's SSH address, your subdomain, an email for Let's Encrypt, your OpenRouter key, your Google OAuth Client ID and Secret, and the login you want for the chat UI. It writes the server's configuration, starts the stack, and creates your account.
4. Once Caddy finishes obtaining its certificate (check with `docker compose logs -f caddy` on the server), your chat UI is live at `https://<your-subdomain>`. Sign in with the account the installer created.
5. Connect each Google service you want. The installer prints these commands filled in, including your bearer token. Ask the server for a consent URL, open it in any browser, and approve. Tokens are minted and stored **on the server**; nothing runs on your machine.
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
6. In LibreChat, enable gMCP's tools for your conversation using the tools control in the message composer. Until you do, the model has no access to them and will tell you it can't reach your data.

> If you already ran `gmcp setup` on a Windows machine, the installer detects `~/.gmcp` and copies those authorizations up instead, so you can skip step 5.

> **Public signup is deliberately disabled.** This server holds *your* Google refresh tokens, and every LibreChat user on it shares a single gMCP credential, so anyone who could register would get read access to your analytics data plus whatever write access you granted. Add more people deliberately instead:
> ```
> ssh you@your-server "cd ~/gmcp-server && docker compose exec api npm run create-user"
> ```

gMCP's own `/mcp` endpoint is also reachable directly at `https://<your-subdomain>/mcp`, protected by the same bearer token (`GMCP_HTTP_TOKEN` in the server's `.env`, printed by the installer). So any other MCP-capable client can connect to your server too, not just LibreChat.

### Adding a service later

Repeat step 5 for the service you want, then restart gMCP. No reinstall, and nothing needed on your own machine.

## Troubleshooting

**"Unable to login with the information provided", but the password is right.**
LibreChat bans an IP for two hours after 7 failed attempts, and a banned IP gets
the same generic message even when the credentials are correct. Restarting clears
it, because that state is held in memory:
```
ssh you@your-server "cd ~/gmcp-server && docker compose restart api"
```
Log in with your email address, not your username.

**The model says it has no access to your Google data.** Its tools aren't enabled
for that conversation. Turn them on with the tools control in the message
composer. Connecting a service is only half of it; the model still has to be given
the tools.

**gMCP stops working roughly weekly.** Your Google OAuth consent screen is in
Testing mode, where Google expires refresh tokens after 7 days. Publish the app to
stop it.

**A tool returns a 403 from Google.** That API isn't enabled in your Cloud
project. They're enabled individually, and GA4 needs two of them (Analytics Admin
API and Analytics Data API).

**`redirect_uri_mismatch` when connecting a service.** The deployment's callback
isn't registered on your OAuth client. Add `https://<your-subdomain>/oauth/callback`
exactly, then retry. Changes can take a few minutes to take effect.

**Newly connected services don't appear.** gMCP registers tools at startup, so
restart it: `docker compose restart gmcp`.

## Read-only vs. read/write

Every service can be connected as **read-only** or **read/write**, chosen per service when you connect it. Read/write access uses genuinely separate OAuth scopes, so a read-only connection is structurally incapable of making write calls.

Any write or mutating action (pausing a GTM tag, for example) always requires a two-step propose and confirm flow. The model first calls a `propose_*` tool that only returns a plain-language summary and a short-lived confirmation token, then a separate `apply_*` tool call carrying that token actually makes the change. No tool can mutate anything in a single call.

Google Ads and Google Business Profile are the two exceptions: Google only offers one combined OAuth scope for each, so "read-only" for those two is enforced in code rather than by scope.
