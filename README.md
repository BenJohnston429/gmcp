# gMCP

A self-hosted MCP (Model Context Protocol) server that gives an LLM conversational, diagnostic access to **your own** Google marketing and analytics data: Google Tag Manager, GA4, Search Console, BigQuery, PageSpeed Insights, AdSense, Google Ads, and Google Business Profile.

Self-hosted by design: your Google OAuth tokens and data stay on infrastructure you control. There's no third-party service sitting between your Google account and the LLM.

## What you can ask it

Once a service is connected, you just ask questions in plain language and the model queries the real API:

- *"Which tags on my site are currently paused in GTM?"*
- *"How did organic clicks change over the last 28 days versus the previous 28?"*
- *"Which landing pages lost the most GA4 traffic month over month?"*
- *"What's the Core Web Vitals score for my slowest page?"*
- *"Query the GA4 export in BigQuery for last week's top converting sources."*

It answers from your live data rather than guessing, and it only ever sees the services you chose to connect.

Anything that **changes** your data works differently. Ask it to *"pause the Hotjar tag"* and it doesn't just do it. It first shows you exactly what will change:

```
Will PAUSE tag "Hotjar Tracking" (accounts/123/containers/456/workspaces/7/tags/89).
Currently active.
```

Nothing happens until you confirm, and the confirmation is a single-use token the server issues and checks itself, rather than the model being trusted to behave. Connect a service as read-only and the write tools aren't offered at all, because the OAuth scope genuinely doesn't permit them.

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

1. Download `gmcp.mcpb` from the [**Releases page**](https://github.com/BenJohnston429/gmcp/releases/latest). It is a release asset, **not a file in this repository**, so cloning or downloading the repo will not give you it.
2. **Quit Claude Desktop completely first**, including from the system tray. If a previous gMCP is still running it holds the binary open, and the installer fails with `EPERM: operation not permitted, chmod`. Then reopen it, go to Settings then Extensions, and **drag `gmcp.mcpb` onto the install screen**. Double-clicking the file does nothing: `.mcpb` has no file association on Windows.
3. You'll be prompted for a Google OAuth Client ID and Secret. Create one at the [Google Cloud Console](https://console.cloud.google.com/apis/credentials) (type: "Web application"), add `http://127.0.0.1:8765` as an authorized redirect URI, then enable whichever Google APIs you want to use (GTM, GA4, Search Console, and so on) in that same Cloud project. They are enabled individually, and GA4 needs two: Analytics Admin API *and* Analytics Data API.
4. **Connect your Google services.** Installing the extension does not do this on its own, and until you do it gMCP has no tools and Claude Desktop will show it as failed. Open a terminal and run the setup wizard, which handles every service in one pass through your browser:
   ```
   "%LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude\Claude Extensions\local.mcpb.ben-johnston.gmcp\server\gmcp.exe" setup
   ```
   Pick the services you want, choose read-only or read/write for each, and approve each Google consent screen as it opens. Then restart Claude Desktop.

### Checking the install worked

The extension unpacks to a deeply nested, virtualised path that is easy to miss. Find it with:
```powershell
Get-ChildItem "$env:LOCALAPPDATA\Packages" -Recurse -Filter "manifest.json" -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like "*Claude Extensions*" } | Select-Object -ExpandProperty FullName
```
A healthy install contains exactly two things: `manifest.json`, and `server\gmcp.exe` at roughly 13MB. If `server\gmcp.exe` is missing, the extension did not unpack properly. Download `gmcp.exe` from the same Releases page and drop it in at that path, which is all the extension needs.

Using a different MCP client (Claude Code, or anything else that supports local/stdio MCP servers)? Point it at that same `gmcp.exe`, and run `gmcp setup` once to do the service and OAuth walkthrough.

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

**The extension shows "Failed" in Claude Desktop.** Two different causes, and they look identical:
1. *No services connected yet.* gMCP registers tools only for services you've authorized, so before setup it has none and appears failed rather than idle. Run `gmcp setup` (step 4 above).
2. *The binary didn't unpack.* Check the extension folder using the command in "Checking the install worked" above. If `server\gmcp.exe` isn't there, download `gmcp.exe` from the Releases page and place it at that path.

**Nothing happens when you double-click `gmcp.mcpb`.** Expected: `.mcpb` has no file association on Windows. Drag it onto Claude Desktop's extensions screen instead.

**"Failed to install extension ... EPERM: operation not permitted, chmod".** Claude Desktop unpacks the bundle and then marks the binary executable, which Windows refuses if something already holds that file open. Almost always a gMCP from a previous install still running. Quit Claude Desktop fully (including the system tray), confirm no `gmcp.exe` remains in Task Manager, and install again. If it keeps happening, `windows/install-gmcp-manually.ps1` in this repo does the same install directly and clears the lock itself:
```
powershell -ExecutionPolicy Bypass -File windows/install-gmcp-manually.ps1 -Bundle C:path	ogmcp.mcpb
```

**`GOOGLE_CLIENT_ID is not set`.** You're running `gmcp.exe` directly rather than through the extension. Installed as an extension, Claude Desktop supplies the credentials you entered at install time. Run standalone and it reads a `.env` from the **current working directory**, not from beside the executable, so run it from the directory holding your `.env`.

**PowerShell "Unexpected token" on a quoted path.** Use the call operator: `& "C:\path with spaces\gmcp.exe" setup`.

**Can't find the extension folder.** It's virtualised under `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude\Claude Extensions\`, not `%APPDATA%\Claude`, even though some log lines say "Roaming". Use the discovery command above.

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

The propose and confirm flow shown at the top of this README is enforced server side, not by prompting. A `propose_*` tool has no side effects: it returns a summary and a short-lived, single-use token. The matching `apply_*` tool accepts *only* that token and reads the change from the server's own store, so it can't be replayed with different values swapped in, and no tool can mutate anything in a single call.

Google Ads and Google Business Profile are the two exceptions: Google only offers one combined OAuth scope for each, so "read-only" for those two is enforced in code rather than by scope.
