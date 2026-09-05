#!/usr/bin/env bash
# Deploys the gMCP + LibreChat + Caddy stack to a remote Docker host, pulling
# a pre-built gMCP image from ghcr.io/benjohnston429/gmcp (this installer
# ships without gMCP's source).
#
# Run this from your own machine, not the server. The SSH user can be root or any
# ordinary user with Docker access — nothing here needs sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== gMCP server installer =="
echo

# Local tokens are optional. If you've already run `gmcp setup` on this machine they
# get copied up as-is; otherwise the server hosts the consent flow itself at the end of
# this script, which is the only path that works if there's no gmcp binary for your OS.
SEED_LOCAL_TOKENS=false
if [ -f "$HOME/.gmcp/token.json" ] && [ -f "$HOME/.gmcp/services.json" ]; then
  SEED_LOCAL_TOKENS=true
  echo "Found ~/.gmcp — your existing Google authorizations will be copied to the server."
else
  echo "No local ~/.gmcp found. You'll connect Google services through the server"
  echo "itself at the end of this install — nothing needs to be installed here."
fi
echo

read -rp "SSH target for the server (e.g. root@1.2.3.4): " SSH_TARGET
read -rp "Public subdomain (DNS must already point at that server's IP, e.g. chat.example.com): " SUBDOMAIN
read -rp "Email for Let's Encrypt certificate notices: " LETSENCRYPT_EMAIL
echo
echo "OpenRouter (its own separate credential, not tied to Google auth)."
echo "Reminder: the account-wide training opt-out (paid/free models, separate toggles) is a"
echo "one-time manual step on https://openrouter.ai/settings/privacy — this installer can't set it."
read -rp "OpenRouter API key: " OPENROUTER_KEY

read -rp "Google OAuth Client ID (same one used for 'gmcp setup'): " GOOGLE_CLIENT_ID
read -rp "Google OAuth Client Secret: " GOOGLE_CLIENT_SECRET

echo
echo "Your LibreChat login. Public signup stays disabled — this server holds your Google"
echo "tokens, and every LibreChat user shares one gMCP credential, so anyone who could"
echo "register here would get your analytics data. This account is created directly instead."
read -rp "Your email: " ADMIN_EMAIL
read -rp "Display name: " ADMIN_NAME
read -rp "Username: " ADMIN_USERNAME
read -rsp "Password: " ADMIN_PASSWORD
echo

GMCP_HTTP_TOKEN="$(grep -o '"token": *"[^"]*"' "$HOME/.gmcp/http_token.json" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || true)"
if [ -z "$GMCP_HTTP_TOKEN" ]; then
  GMCP_HTTP_TOKEN="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())')"
fi

echo
echo "== Deploying to $SSH_TARGET =="

# Deploy under the SSH user's own home rather than a hardcoded /root, so this works
# whether you log in as root or as an ordinary user with Docker access.
REMOTE_DIR="$(ssh "$SSH_TARGET" 'echo "$HOME"')/gmcp-server"
REMOTE_UID="$(ssh "$SSH_TARGET" id -u)"
REMOTE_GID="$(ssh "$SSH_TARGET" id -g)"

# Which uid the gmcp container runs as. Deploying as root, keep it on the image's own
# unprivileged user and chown the token store to match — the whole point is that the
# one internet-facing service isn't uid 0. Deploying as a normal user, run it as you
# instead, so the bind-mounted token store is writable without a chown (which would
# need root anyway, defeating the "no sudo" part).
if [ "$REMOTE_UID" = "0" ]; then
  GMCP_UID=10001
  GMCP_GID=10001
else
  GMCP_UID="$REMOTE_UID"
  GMCP_GID="$REMOTE_GID"
fi
echo "Deploying to $REMOTE_DIR (gmcp will run as uid $GMCP_UID)."

echo "Copying installer files to remote host…"
ssh "$SSH_TARGET" "mkdir -p $REMOTE_DIR"
scp "$SCRIPT_DIR/docker-compose.yml" "$SCRIPT_DIR/Caddyfile" "$SCRIPT_DIR/librechat.yaml" \
  "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/rewrite_env.py" \
  "$SSH_TARGET:$REMOTE_DIR/"

ssh "$SSH_TARGET" "mkdir -p $REMOTE_DIR/gmcp-data"
if [ "$SEED_LOCAL_TOKENS" = true ]; then
  echo "Seeding gMCP's authorized token store…"
  scp "$HOME/.gmcp/token.json" "$HOME/.gmcp/services.json" \
    "$SSH_TARGET:$REMOTE_DIR/gmcp-data/"
fi
# These are Google refresh tokens, and scp doesn't reliably carry restrictive modes
# across, so set them explicitly rather than trusting the transfer. The chown only
# happens (and is only possible) when deploying as root; otherwise the files are
# already owned by the user the container runs as.
ssh "$SSH_TARGET" "chmod 700 $REMOTE_DIR/gmcp-data \
  && chmod 600 $REMOTE_DIR/gmcp-data/*.json 2>/dev/null || true"
if [ "$REMOTE_UID" = "0" ]; then
  ssh "$SSH_TARGET" "chown -R $GMCP_UID:$GMCP_GID $REMOTE_DIR/gmcp-data"
fi

echo "Writing .env…"
ssh "$SSH_TARGET" "cp $REMOTE_DIR/.env.example $REMOTE_DIR/.env"

# .env.example already carries blank placeholder lines for most of these keys
# (SUBDOMAIN, OPENROUTER_KEY, GOOGLE_CLIENT_ID, CREDS_KEY, JWT_SECRET, etc.) —
# appending new lines via `cat >>` instead of replacing them creates duplicate
# keys, and whichever value a given consumer's env-file parser picks first can
# silently differ from what's on the last line. rewrite_env.py (copied above)
# does a real key=value replacement instead, reading values over stdin so
# nothing has to be escaped into a shell or sed command line.
random_hex() {
  ssh "$SSH_TARGET" "openssl rand -hex $1 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex($1))'"
}
random_uuid() {
  ssh "$SSH_TARGET" "cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid; print(uuid.uuid4())'"
}

ssh "$SSH_TARGET" "python3 $REMOTE_DIR/rewrite_env.py $REMOTE_DIR/.env" <<EOF
SUBDOMAIN=$SUBDOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
OPENROUTER_KEY=$OPENROUTER_KEY
GMCP_GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID
GMCP_GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET
GMCP_HTTP_TOKEN=$GMCP_HTTP_TOKEN
ALLOW_REGISTRATION=false
DOMAIN_CLIENT=https://$SUBDOMAIN
DOMAIN_SERVER=https://$SUBDOMAIN
MEILI_MASTER_KEY=$(random_uuid)
ADMIN_PANEL_SESSION_SECRET=$(random_uuid)
CREDS_KEY=$(random_hex 32)
CREDS_IV=$(random_hex 16)
JWT_SECRET=$(random_hex 32)
JWT_REFRESH_SECRET=$(random_hex 32)
UID=$REMOTE_UID
GID=$REMOTE_GID
GMCP_UID=$GMCP_UID
GMCP_GID=$GMCP_GID
EOF

# .env now holds the OpenRouter key, Google client secret, gMCP's bearer token and
# LibreChat's JWT/encryption secrets — it should not be world-readable.
ssh "$SSH_TARGET" "chmod 600 $REMOTE_DIR/.env"

echo "Pulling images and starting the stack (this takes a while the first time)…"
ssh "$SSH_TARGET" "cd $REMOTE_DIR && docker compose pull && docker compose up -d"

echo "Creating your LibreChat account…"
# Signup is disabled, so the first account is created directly against the running
# container. The password goes over stdin rather than as an argument so it doesn't
# land in the server's process list — create-user prompts for whatever it isn't given.
for _ in $(seq 1 30); do
  if ssh "$SSH_TARGET" "cd $REMOTE_DIR && docker compose exec -T api test -f /app/config/create-user.js" 2>/dev/null; then
    break
  fi
  sleep 5
done
printf '%s\n' "$ADMIN_PASSWORD" | ssh "$SSH_TARGET" \
  "cd $REMOTE_DIR && docker compose exec -T api npm run create-user -- \
   '$ADMIN_EMAIL' '$ADMIN_NAME' '$ADMIN_USERNAME' --email-verified=true"

echo
echo "Done. https://$SUBDOMAIN should be reachable once Caddy obtains its certificate"
echo "(check with: ssh $SSH_TARGET 'cd $REMOTE_DIR && docker compose logs -f caddy')."
echo "Sign in as $ADMIN_EMAIL. Public signup is off; add more people later with:"
echo "  ssh $SSH_TARGET \"cd $REMOTE_DIR && docker compose exec api npm run create-user\""

if [ "$SEED_LOCAL_TOKENS" = false ]; then
  cat <<MSG

== Connecting Google services ==

Before this works, add the redirect URI to your Google OAuth client
(console.cloud.google.com -> Credentials -> your "Web application" client):

  https://$SUBDOMAIN/oauth/callback

Then connect each service you want. This asks the server for a consent URL, which
you open in any browser — the tokens are minted and stored on the server, so
nothing has to be installed on this machine:

  curl -s -X POST https://$SUBDOMAIN/oauth/start \\
    -H 'Authorization: Bearer $GMCP_HTTP_TOKEN' \\
    -H 'Content-Type: application/json' \\
    -d '{"service":"ga4","access":"readonly"}'

That bearer token is gMCP's own (not Google's). It's also what any other remote MCP
client uses to reach https://$SUBDOMAIN/mcp, so keep it somewhere safe:

  $GMCP_HTTP_TOKEN

Services: gtm, ga4, search_console, bigquery, pagespeed, adsense, google_ads, gbp.
Use "access":"readwrite" only where you want write tools (gtm supports it).
After connecting, restart gMCP so it registers the new tools:

  ssh $SSH_TARGET "cd $REMOTE_DIR && docker compose restart gmcp"
MSG
fi
