# gMCP

A self-hosted MCP (Model Context Protocol) server that gives an LLM conversational, diagnostic access to **your own** Google marketing and analytics data: Google Tag Manager, GA4, Search Console, BigQuery, PageSpeed Insights, AdSense, Google Ads, and Google Business Profile.

Self-hosted by design: your Google OAuth tokens and data stay on infrastructure you control. There's no third-party service sitting between your Google account and the LLM.

The server itself is written in Rust. This repo publishes only the two installers (a Claude Desktop bundle and a server deploy script), not the source, so you won't find any Rust here and GitHub's own language stats for this repo won't reflect it either. That's deliberate, and it's also why you don't need Rust, or any build toolchain, installed to use either install path.

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
| Who does the Google consent | You, on a Connect page that runs on your PC | You, on a Connect page on your server's site |

Both paths connect the same underlying services. Pick as many or as few Google products as you've actually got access to; gMCP only exposes tools for the ones you connect.

## Windows local install (Claude Desktop)

1. Download `gmcp.mcpb` from the [**Releases page**](https://github.com/BenJohnston429/gmcp/releases/latest). It is a release asset, **not a file in this repository**, so cloning or downloading the repo will not give you it.
2. **Create a Desktop app OAuth client.** In the [Google Cloud Console](https://console.cloud.google.com/auth/clients), go to **Google Auth Platform → Clients**, click **Create client**, choose **Desktop app** as the application type, and create it. Download the JSON it offers, or copy the Client ID and Secret straight away: Google only shows the secret in full when you create it. There's no redirect address to add, because a Desktop app client accepts sign-ins back to your own PC by itself. If you also run the server install, give each its own client: the server needs a "Web application" one.

   Then enable whichever Google APIs you want to use (GTM, GA4, Search Console, and so on) in that same Cloud project. They are enabled individually, and GA4 needs two: Analytics Admin API *and* Analytics Data API. Before connecting anything, see **"Publish your consent screen"** under the server install section below: it applies here too, and skipping it means every service you connect will quietly stop working after about a week.
3. **Quit Claude Desktop completely first**, including from the system tray. If a previous gMCP is still running it holds the binary open, and the installer fails with `EPERM: operation not permitted, chmod`. Then reopen it, go to Settings then Extensions, and **drag `gmcp.mcpb` onto the install screen**. Double-clicking the file does nothing: `.mcpb` has no file association on Windows. When it asks, paste your Desktop app client's **Client ID** and **Client Secret**. The PageSpeed key and Google Ads developer token are optional.
4. **Connect your Google services.** Start a new chat in Claude Desktop and ask: *"Open the gMCP Connect page"*. Allow gMCP's tool when Claude asks, and the page opens in your browser, ready to use. Click **Connect** next to each service you want (for Tag Manager, choose **Read only** or **Read and write** first), and approve it in the tab Google opens. When that tab says the sign-in was received, close it: the service now shows **Connected**.
5. **Start a new chat to use them.** If a newly connected service's tools don't appear, quit Claude Desktop fully (including from the system tray) and reopen it.

The Connect page runs on your own PC, only while Claude Desktop is open, and its link only works on that PC. It shows the same statuses as a server install's: it tells you when a sign-in has expired, with a button to connect it again, and when a Google API a service needs is switched off, with a button to Google's page that switches it on. To add a service later, or reconnect one, just ask Claude to open it again.

> **After changing gMCP's settings in Claude Desktop** (the Client ID, Secret or optional keys), quit Claude Desktop fully from the system tray and reopen it. Claude Desktop runs more than one copy of gMCP, and saving settings only restarts one of them; the other carries on with the old values until you quit.

### Checking the install worked

Where the extension unpacks depends on your Claude Desktop version, and both places are easy to miss. Find it with:
```powershell
Get-ChildItem "$env:LOCALAPPDATA\Claude-Data", "$env:LOCALAPPDATA\Packages" -Recurse -Filter "manifest.json" -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -like "*Claude Extensions*gmcp*" } | Select-Object -ExpandProperty FullName
```
A healthy install contains exactly two things: `manifest.json`, and `server\gmcp.exe` at roughly 14MB. If `server\gmcp.exe` is missing, the extension did not unpack properly. Download `gmcp.exe` from the same Releases page and drop it in at that path, which is all the extension needs.

Using a different MCP client (Claude Code, or anything else that supports local/stdio MCP servers)? Point it at that same `gmcp.exe` with the argument `serve`, with `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` set, and ask it to open the gMCP Connect page. Any client running gMCP this way gets that tool.

Mac and Linux users: there's no pre-built binary for your platform yet. Use the server install below, which needs nothing installed on your own machine at all.

## Server install (Docker + LibreChat, any Linux host)

This deploys gMCP alongside [LibreChat](https://www.librechat.ai/) (a full chat UI) and [Caddy](https://caddyserver.com/) (automatic HTTPS), all behind one subdomain you point at the server.

**Before you start, you need:**
- A Linux server with Docker and Docker Compose installed (a DigitalOcean droplet, or any other VPS), reachable over SSH. 2GB RAM is enough: the full eight-container stack was measured using about 1GB on a stock 2GB droplet, with no swap. Log in as **a non-root user with `sudo`** (recommended), rather than as `root`. The installer deploys into that user's home folder and never uses `sudo` itself. That user also needs to be in the `docker` group, and if it isn't yet, the installer offers to add it for you, asking for its sudo password once. Logging in as `root` works too.
- A subdomain's DNS **A record already pointing at that server's IP**. Caddy needs this to complete its Let's Encrypt certificate challenge.
- An [OpenRouter](https://openrouter.ai/) API key, which is what powers the chat model and is separate from your Google credentials. Before deploying, set the account-wide training opt-out at [openrouter.ai/settings/privacy](https://openrouter.ai/settings/privacy). The installer bakes Zero Data Retention into every request automatically, but that one opt-out toggle is manual.
- A Google Cloud project with a **"Web application"** OAuth client (Client ID and Secret), and the APIs you want **enabled in that project**. They're each separate: Tag Manager API, Google Analytics Admin API *and* Google Analytics Data API (GA4 needs both), Search Console API, BigQuery API, AdSense Management API, PageSpeed Insights API.
- On your own machine, just `bash`, `ssh` and `curl`. No gMCP binary, no Rust, no Docker. (On Windows, Git Bash or WSL.)

### Publish your consent screen so you only authorise once

Your OAuth consent screen starts in **Testing** mode, where Google caps it at 100 users and, more importantly, expires every refresh token after 7 days no matter what. That's Google's own policy, not something gMCP can work around in code, so every service you've connected quietly breaks about once a week until you publish it.

This is entirely **your own** Google Cloud project, so publishing only affects people you've personally authorised, nobody else's. It doesn't touch what any individual user's token can see or do, and every reader following this guide creates and publishes their own, separately. Nobody shares a client, and nobody but you is ever responsible for another person's data here.

- In the [Google Cloud Console](https://console.cloud.google.com/apis/credentials), go to **APIs & Services → OAuth consent screen** (sometimes labelled **Audience**), and click **Publish App**.
- Expect Google to route you into its verification process rather than publishing on the spot. The Google APIs gMCP uses are all on Google's "sensitive" list, so it asks for a privacy policy URL and a short justification per scope, sometimes a screen recording of the consent flow, and then a review that can take days to weeks.
- Once it's through, you're done: no more weekly re-auth.
- Or skip it and stay in Testing, reconnecting each service roughly once a week: your Connect page shows it as **Sign-in expired**, with a button to connect it again (on Windows, ask Claude to open the page). The trade-off is entirely convenience, not security, either way.

**Steps:**

1. In the [Google Cloud Console](https://console.cloud.google.com/apis/credentials), open your "Web application" OAuth client and add this **Authorized redirect URI** (Google matches it exactly):
   ```
   https://<your-subdomain>/oauth/callback
   ```
2. **Get the installer onto your own computer, not the server.** You run it from your own machine and it does all the work on the server over SSH, so there's nothing to clone or copy onto the server yourself. Open a terminal (Git Bash on Windows, Terminal on Mac or Linux), go to any folder you like (your home folder is fine), and run:
   ```
   git clone https://github.com/BenJohnston429/gmcp.git
   cd gmcp/server
   ```
   No git? On this repo's GitHub page, click **Code**, then **Download ZIP**, extract it, and open your terminal in the extracted folder's `server` folder instead.

   Before going further, check you can reach your server: `ssh you@<your-server>` should log you in (type `exit` to come back). `you` is your sudo user (a brand-new DigitalOcean droplet only has `root` until you create one). If it asks whether to trust the server's fingerprint, answer `yes`; that only happens the first time.
3. **Run it**, from that `server` folder:
   ```
   bash install.sh
   ```
   If your SSH key has a passphrase, unlock it for this terminal first with `eval "$(ssh-agent -s)"` and then `ssh-add`. The installer connects to the server many times, so it needs to log in without prompting. It checks that straight after you give it the server's address, and stops with an explanation if it can't, before asking for anything else.

   It asks for these, in this order:

   | It asks for | What to enter |
   |---|---|
   | SSH target for the server | What you just tested, e.g. `ben@203.0.113.10` |
   | Public subdomain | Just the name, e.g. `chat.example.com`, with no `https://` |
   | Email for Let's Encrypt | Any address you read; certificate notices go there |
   | OpenRouter API key | Your key from openrouter.ai |
   | Google OAuth Client ID, then Secret | From your "Web application" OAuth client |
   | Your email, display name, username, password | The login you want for the chat UI. The password stays hidden as you type, and is asked for twice |

   Each key is checked as you enter it: the OpenRouter key with OpenRouter, and the Google Client ID and Secret with Google. If one doesn't work, or a paste didn't come through, it says so and asks again, so a mistyped key can't end up on your server. (In Git Bash, paste with right-click or Shift+Insert. Ctrl+V types an invisible character instead.)

   Then it does the rest by itself, which takes several minutes the first time:
   - checks it can log in and use Docker. If your user isn't in the `docker` group yet, it asks whether to add it, then asks for that user's sudo password once (it's sent to `sudo` over the SSH connection, never shown or stored, and the group is the only thing changed);
   - creates a `gmcp-server` folder in that user's home folder (so `/home/ben/gmcp-server` for a user called `ben`), and copies the stack's configuration there;
   - writes the server's `.env` from your answers, generating its own secrets, with owner-only permissions;
   - downloads and starts everything (gMCP, LibreChat and its databases, and Caddy);
   - creates your chat login and checks it can sign in;
   - prints gMCP's bearer token and the commands for step 5. Keep the token somewhere safe.

   Nothing is installed on your own computer. The folder you cloned isn't needed again once the installer finishes, so you can delete it.
4. Once Caddy finishes obtaining its certificate (check with `docker compose logs -f caddy` on the server), your chat UI is live at `https://<your-subdomain>`. Sign in with the account the installer created.
5. **Connect your Google services on your Connect page.** Open `https://<your-subdomain>/connect` in any browser, and unlock it with your gMCP access token (the installer prints it at the end; it's also `GMCP_HTTP_TOKEN` in the server's `.env`). Click **Connect** next to each service you want, and approve it in the tab Google opens. For Tag Manager, you can choose read only or read and write first.

   Each service reaches your chat straight away, with no restart. The sign-in is stored **on the server**, so nothing is installed on your machine. Come back to the same page any time:
   - a sign-in that has expired shows as **Sign-in expired**, with a button to reconnect it;
   - a Google API that's switched off in your Cloud project shows as **Switched off**, with a button that takes you straight to Google's page to switch it on.

   The token stays in that browser tab only, and is forgotten when you close it.

   <details>
   <summary>Connecting from the terminal instead</summary>

   Either of these prints a Google consent link to open in any browser:
   ```
   ssh you@<your-server> "cd ~/gmcp-server && docker compose exec gmcp gmcp auth login ga4"
   ```
   ```
   curl -s -X POST https://<your-subdomain>/oauth/start \
     -H 'Authorization: Bearer <your GMCP_HTTP_TOKEN>' \
     -H 'Content-Type: application/json' \
     -d '{"service":"ga4","access":"readonly"}'
   ```
   Services: `gtm`, `ga4`, `search_console`, `bigquery`, `pagespeed`, `adsense`, `google_ads`, `gbp`. Each link works for 10 minutes. For write tools (currently only `gtm` has any), end the first command with `gmcp auth login gtm --access readwrite` (inside the quotes), or use `"access":"readwrite"` in the second.
   </details>
6. In LibreChat, enable gMCP's tools for your conversation using the tools control in the message composer. Until you do, the model has no access to them and will tell you it can't reach your data.

> If you've already used gMCP's Windows version on the computer you run the installer from, it finds those Google sign-ins (in `~/.gmcp`) and asks whether to copy them to the server. Say yes only if they were made with the same OAuth client you're giving the installer; otherwise, the default no is right, and you connect services on the Connect page instead.

> **Public signup is deliberately disabled.** This server holds *your* Google refresh tokens, and every LibreChat user on it shares a single gMCP credential, so anyone who could register would get read access to your analytics data plus whatever write access you granted. Add more people deliberately instead:
> ```
> ssh you@your-server "cd ~/gmcp-server && docker compose exec api npm run create-user"
> ```

gMCP's own `/mcp` endpoint is also reachable directly at `https://<your-subdomain>/mcp`, protected by the same bearer token (`GMCP_HTTP_TOKEN` in the server's `.env`, printed by the installer). So any other MCP-capable client can connect to your server too, not just LibreChat.

### Adding a service later

Open your Connect page and click **Connect** next to it. No reinstall, no restart, and nothing needed on your own machine.

### Updating

Updating keeps your connected services, your chat account and your settings. From the `server/` folder of a fresh copy of this repo, copy the latest stack files to your server, then pull the new gMCP and restart it and Caddy:
```
scp docker-compose.yml Caddyfile you@<your-server>:~/gmcp-server/
ssh you@<your-server> "cd ~/gmcp-server && docker compose pull gmcp && docker compose up -d gmcp && docker compose restart caddy"
```

Installs from before v0.3.0 need this before the Connect page will appear.

### You're not locked into OpenRouter

It's the default because one key gives you a wide range of models plus the Zero Data Retention and no-training request parameters this stack bakes into every call, but LibreChat itself doesn't require it.

Any signed-in user can add their own key directly in the chat UI, no config change or restart needed. `.env.example` already has `OPENAI_API_KEY`, `ANTHROPIC_API_KEY` and `GOOGLE_KEY` set to `user_provided`, LibreChat's convention for "each user supplies their own key rather than the server having one baked in". Pick that provider in the model picker and paste a key in.

You can also add more providers server-side by editing `librechat.yaml`: `endpoints.custom` is a list, and OpenRouter is just the one entry here. Add another block for any OpenAI-API-compatible provider (Groq, Together, a direct Anthropic-compatible endpoint) and restart the `api` container.

One thing worth knowing either way: the ZDR and data-collection-denial parameters only apply to the OpenRouter entry, since they're OpenRouter-specific request fields. A user's own key to another provider talks to that provider directly, under whatever privacy terms that provider offers, none of gMCP's own.

## Troubleshooting

**The extension shows "Failed" in Claude Desktop.** Usually the binary didn't unpack. Check the extension folder using the command in "Checking the install worked" above. If `server\gmcp.exe` isn't there, download `gmcp.exe` from the Releases page and place it at that path. (Versions before 0.3.1 also showed as failed until you'd connected a service. That no longer happens: gMCP always has its Connect page tool.)

**Google says "Error 400: redirect_uri_mismatch", or calls gMCP "an app that's being tested", when you connect from the Windows Connect page.** gMCP is using a different OAuth client from the one you meant: a "Web application" client gives the mismatch, and a client from a project still in Testing gives the second. Check that gMCP's settings in Claude Desktop hold your **Desktop app** client's Client ID and Secret, from your published project. Then quit Claude Desktop fully from the system tray and reopen it, because saving settings only restarts one of Claude Desktop's copies of gMCP.

**The Connect page won't load, or asks you to open it from your AI app.** The page only runs while Claude Desktop is open, and gets a new address each time it starts. Ask Claude to open the gMCP Connect page again.

**"Couldn't listen for Google's redirect on 127.0.0.1:8765".** Another Google sign-in for gMCP is still waiting, usually one you started and then closed Google's tab on. It gives up by itself after 10 minutes, or quit Claude Desktop fully and reopen it to clear it straight away.

**A newly connected service's tools don't appear in Claude Desktop.** Start a new chat. If they still don't appear, quit Claude Desktop fully (including from the system tray) and reopen it.

**Nothing happens when you double-click `gmcp.mcpb`.** Expected: `.mcpb` has no file association on Windows. Drag it onto Claude Desktop's extensions screen instead.

**"Failed to install extension ... EPERM: operation not permitted, chmod".** Claude Desktop unpacks the bundle and then marks the binary executable, which Windows refuses if something already holds that file open. Almost always a gMCP from a previous install still running. Quit Claude Desktop fully (including the system tray), confirm no `gmcp.exe` remains in Task Manager, and install again. If it keeps happening, `windows/install-gmcp-manually.ps1` in this repo does the same install directly and clears the lock itself:
```
powershell -ExecutionPolicy Bypass -File windows\install-gmcp-manually.ps1 -Bundle "C:\path\to\gmcp.mcpb"
```

**`GOOGLE_CLIENT_ID is not set`.** You're running `gmcp.exe` directly rather than through the extension. Installed as an extension, Claude Desktop supplies the credentials you entered at install time. Run standalone and it reads a `.env` from the **current working directory**, not from beside the executable, so run it from the directory holding your `.env`.

**PowerShell "Unexpected token" on a quoted path.** Use the call operator: `& "C:\path with spaces\gmcp.exe" setup`.

**Can't find the extension folder.** Newer versions of Claude Desktop keep it under `%LOCALAPPDATA%\Claude-Data\claude_<id>\Claude Extensions\`, and older ones under `%LOCALAPPDATA%\Packages\Claude_<id>\LocalCache\Roaming\Claude\Claude Extensions\`. Neither is `%APPDATA%\Claude`, even though some log lines say "Roaming". Use the discovery command above.

**The installer stops with "Permission denied (publickey)".** It couldn't log in to your server without a prompt. In order of likelihood:
1. *Your key has a passphrase that isn't unlocked for this terminal.* Run `eval "$(ssh-agent -s)"`, then `ssh-add`, type the passphrase, and run the installer again. On Windows, if `ssh` works from PowerShell but not from Git Bash, your key is unlocked in Windows' own ssh-agent, which Git Bash's `ssh` can't use. Either `ssh-add` as above, or run `export PATH="/c/Windows/System32/OpenSSH:$PATH"` in Git Bash so it uses Windows' `ssh` instead.
2. *The wrong user name.* A new DigitalOcean droplet only has `root` until you add other users.
3. *Your key isn't on the server.* `ssh you@<your-server>` should log you in by hand.

**The installer pauses for a minute or more, or SSH says "Connection timed out during
banner exchange".** Your server is rate-limiting SSH. DigitalOcean's Docker image, for
one, allows about six new SSH connections from one address in 30 seconds and holds the
rest back. The installer keeps well under that, but other SSH sessions you open from the
same network at the same time count towards it too. Wait a minute, avoid other SSH
connections while the installer runs, and try again.

**"Unable to login with the information provided", but the password is right.**
LibreChat bans an IP for two hours after 7 failed attempts, and a banned IP gets
the same generic message even when the credentials are correct. Restarting clears
it, because that state is held in memory:
```
ssh you@your-server "cd ~/gmcp-server && docker compose restart api"
```
Log in with your email address, not your username.

**The chat says "The model provider could not complete this request. Connection error."** LibreChat can't reach the AI model, almost always because the OpenRouter key on the server is wrong or empty. Installers from before 21 October 2026 accepted a failed paste without checking. Put the right key in place without reinstalling. This asks for the key without showing it, ignores a paste that came through empty (it just asks again), and restarts the chat so it picks the key up:
```
K=""; while [ -z "$K" ]; do read -rsp "OpenRouter key: " K; echo; K="$(printf '%s' "$K" | tr -d '[:space:][:cntrl:]')"; done; echo "Got ${#K} characters."; printf 'OPENROUTER_KEY=%s\n' "$K" | ssh you@<your-server> "cd ~/gmcp-server && python3 rewrite_env.py .env && chmod 600 .env && docker compose restart api"; unset K
```
**The model says it has no access to your Google data.** Its tools aren't enabled
for that conversation. Turn them on with the tools control in the message
composer. Connecting a service is only half of it; the model still has to be given
the tools.

**gMCP stops working roughly weekly, or a tool call fails saying a service "needs
reauthorization".** Your Google OAuth consent screen is in Testing mode, where Google
expires every refresh token after 7 days regardless of use. See "Publish your consent
screen" above, under the server prerequisites, for how to stop it recurring.

**A tool returns a 403 from Google.** That API isn't enabled in your Cloud
project. They're enabled individually, and GA4 needs two of them (Analytics Admin
API and Analytics Data API).

**`redirect_uri_mismatch` when connecting a service.** The deployment's callback
isn't registered on your OAuth client. Add `https://<your-subdomain>/oauth/callback`
exactly, then retry. Changes can take a few minutes to take effect. Google matches
capital letters too, so `oauth` must be lowercase: `/OAuth/callback` is a different
address as far as Google is concerned, and an easy slip to make.

**Signing in to a service ends with "Could not save the authorization".** Your install
predates a fix for installs as a non-root (sudo) user, where gMCP couldn't reach its own
storage. Update its `docker-compose.yml` from a fresh copy of this repo, from that copy's
`server/` folder:
```
scp docker-compose.yml you@<your-server>:~/gmcp-server/
ssh you@<your-server> "cd ~/gmcp-server && docker compose up -d gmcp"
```
Then sign in to the service again. Nothing else is affected.

**`gmcp auth login` says "couldn't reach gMCP's server".** On a server install the sign-in is caught by the running gMCP container, so it has to be up: `docker compose up -d gmcp`, then rerun the command.

**`/connect` shows the chat site or nothing, instead of the Connect page.** Your install
is from before v0.3.0: see "Updating".

**The Connect page says "That access token wasn't accepted".** Check you copied all of
it. It's also in your server's settings:
`ssh you@<your-server> "grep GMCP_HTTP_TOKEN ~/gmcp-server/.env"`.

**Newly connected services don't appear in the chat.** Start a new conversation, and
check gMCP's tools are switched on for it in the message box. If they still don't
appear, restart gMCP: `docker compose restart gmcp`. (Installs from before v0.3.0
always need that restart after connecting a service: see "Updating".)

## Read-only vs read/write

Every service can be connected as **read-only** or **read/write**, chosen per service when you connect it. Read/write access uses genuinely separate OAuth scopes, so a read-only connection is structurally incapable of making write calls.

The propose and confirm flow shown at the top of this README is enforced server side, not by prompting. A `propose_*` tool has no side effects: it returns a summary and a short-lived, single-use token. The matching `apply_*` tool accepts *only* that token and reads the change from the server's own store, so it can't be replayed with different values swapped in, and no tool can mutate anything in a single call.

Google Ads and Google Business Profile are the two exceptions: Google only offers one combined OAuth scope for each, so "read-only" for those two is enforced in code rather than by scope.
