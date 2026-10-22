#!/usr/bin/env bash
# Deploys the gMCP + LibreChat + Caddy stack to a remote Docker host, pulling
# a pre-built gMCP image from ghcr.io/benjohnston429/gmcp (this installer
# ships without gMCP's source).
#
# Run this from your own machine, not the server. The SSH user can be root or any
# ordinary user with Docker access. Nothing here needs sudo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== gMCP server installer =="
echo

# Local tokens are optional. If you've already run `gmcp setup` on this machine they
# get copied up as-is; otherwise the server hosts the consent flow itself at the end of
# this script, which is the only path that works if there's no gmcp binary for your OS.
SEED_LOCAL_TOKENS=false
# Sign-ins left on this computer by gMCP's Windows version only work on the server if
# they were made with the same OAuth client as this install. Often they weren't (a
# reader tries the Windows version first, then makes a new client for the server), and
# copying them silently gave the server stale, failing connections. So ask, and
# default to no: connecting afresh on the Connect page takes a minute.
if [ -f "$HOME/.gmcp/token.json" ] && [ -f "$HOME/.gmcp/services.json" ]; then
  echo "This computer has Google sign-ins from gMCP's Windows version (in ~/.gmcp)."
  echo "They only work on the server if they were made with the same Google OAuth client"
  echo "you're about to enter. If you're not sure, say no and connect your services on"
  echo "your Connect page after the install instead."
  read -rp "Copy them to the server? [y/N] " COPY_LOCAL_SIGNINS
  case "$COPY_LOCAL_SIGNINS" in
    [yY]*) SEED_LOCAL_TOKENS=true; echo "They'll be copied." ;;
  esac
fi
echo

read -rp "SSH target for the server (e.g. root@1.2.3.4): " SSH_TARGET

# Check the login now, before asking for any keys or passwords. The installer connects
# to the server many times, so it needs a login that works without prompting, and
# finding that out only after every secret has been typed means typing them all again.
# accept-new trusts a server seen for the first time (what answering "yes" to ssh's
# fingerprint question does) but still refuses one whose key has changed.
echo "Checking you can log in to $SSH_TARGET…"
if ! SSH_CHECK="$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new "$SSH_TARGET" true 2>&1)"; then
  {
    echo
    echo "Couldn't log in to $SSH_TARGET without being prompted, and the installer needs"
    echo "to, because it connects to the server many times. SSH said:"
    echo
    printf '%s\n' "$SSH_CHECK" | grep -v '^Warning: Permanently added' | sed 's/^/  /'
    echo
    case "$SSH_CHECK" in
      *"Permission denied"*)
        echo "The usual causes, most likely first:"
        echo
        echo "1. Your key has a passphrase, and nothing is holding it unlocked for this"
        echo "   terminal. Unlock it once, then run the installer again:"
        echo
        echo '     eval "$(ssh-agent -s)"'
        echo '     ssh-add'
        echo
        echo "   On Windows, if your key is already unlocked in Windows' own ssh-agent (so"
        echo "   ssh works from PowerShell but not from here), you can instead make this"
        echo "   terminal use Windows' ssh:"
        echo
        echo '     export PATH="/c/Windows/System32/OpenSSH:$PATH"'
        echo
        echo "2. The wrong user name. A new DigitalOcean droplet only has the user \"root\""
        echo "   until you add others, so try root@ followed by the server's IP."
        echo
        echo "3. Your key isn't on the server. Check that this logs you in by hand:"
        echo "     ssh $SSH_TARGET"
        ;;
      *"REMOTE HOST IDENTIFICATION HAS CHANGED"*|*"Host key verification failed"*)
        echo "The server's identity doesn't match the one this computer remembers. That's"
        echo "expected if you rebuilt or replaced the server at the same address; if so,"
        echo "forget the old one and run the installer again:"
        echo
        echo "     ssh-keygen -R ${SSH_TARGET#*@}"
        echo
        echo "If you haven't changed the server, stop and find out why before continuing."
        ;;
      *)
        echo "Check the address is right, the server is running, and it accepts SSH"
        echo "connections (port 22). This should log you in by hand:"
        echo "     ssh $SSH_TARGET"
        ;;
    esac
  } >&2
  exit 1
fi
echo "Login works."

# A non-root user also needs to run Docker without sudo, because the installer never
# uses sudo. A sudo user isn't automatically in the "docker" group, and following a
# standard "create a sudo user" guide leaves them out of it, so check this now too,
# for the same reason as the login check above.
DOCKER_STATE="$(ssh -n -o BatchMode=yes -o ConnectTimeout=15 "$SSH_TARGET" \
  'if ! command -v docker >/dev/null 2>&1; then echo "missing:$(id -un)";
   elif ! docker info >/dev/null 2>&1; then echo "denied:$(id -un)";
   elif ! docker compose version >/dev/null 2>&1; then echo "no-compose:$(id -un)";
   else echo "ok:$(id -un)"; fi' 2>/dev/null || echo "unknown:")"
REMOTE_USER="${DOCKER_STATE#*:}"
case "$DOCKER_STATE" in
  ok:*)
    echo "Docker works for $REMOTE_USER."
    ;;
  denied:*)
    docker_group_by_hand() {
      {
        echo
        echo "To do it yourself, log in to the server and run:"
        echo
        echo "     sudo usermod -aG docker $REMOTE_USER"
        echo
        echo "then run the installer again. (If $REMOTE_USER is already in the group, Docker"
        echo "itself may not be running: check with \"sudo systemctl status docker\".)"
      } >&2
      exit 1
    }
    echo
    echo "$REMOTE_USER can't use Docker yet. That's normal for a sudo user: running Docker"
    echo "without sudo needs membership of the \"docker\" group, which the installer relies on"
    echo "because it never uses sudo itself. Being in that group gives root-level control of"
    echo "the server through Docker, the same as any Docker host."
    read -rp "Add $REMOTE_USER to the docker group now? [Y/n] " ADD_TO_DOCKER
    case "$ADD_TO_DOCKER" in
      [nN]*) docker_group_by_hand ;;
    esac
    # Try passwordless sudo first; otherwise ask for the password once and hand it to
    # sudo over the SSH connection's stdin, so it's never shown, never put on a
    # command line, and never stored. The only change made is the group membership.
    if ! ssh -n -o BatchMode=yes "$SSH_TARGET" "sudo -n usermod -aG docker '$REMOTE_USER'" 2>/dev/null; then
      read -rsp "Sudo password for $REMOTE_USER on the server (used once, not stored): " SUDO_PASSWORD
      echo
      if ! printf '%s\n' "$SUDO_PASSWORD" | ssh -o BatchMode=yes "$SSH_TARGET" \
          "sudo -S -p '' usermod -aG docker '$REMOTE_USER'" 2>/dev/null; then
        unset SUDO_PASSWORD
        echo "That didn't work: the password was wrong, or $REMOTE_USER isn't allowed to use sudo." >&2
        docker_group_by_hand
      fi
      unset SUDO_PASSWORD
    fi
    # Group changes apply from the next login, and every check is a fresh SSH login, so
    # this sees the new membership without restarting anything.
    if ssh -n -o BatchMode=yes "$SSH_TARGET" 'docker info >/dev/null 2>&1'; then
      echo "Added. Docker works for $REMOTE_USER."
    else
      echo "$REMOTE_USER is in the docker group now, but Docker still isn't answering." >&2
      docker_group_by_hand
    fi
    ;;
  missing:*)
    echo "Docker isn't installed on the server. DigitalOcean's Docker one-click image has it" >&2
    echo "built in; on other hosts, install Docker Engine with the Compose plugin first." >&2
    exit 1
    ;;
  no-compose:*)
    echo "Docker is installed but the Compose plugin isn't (\"docker compose\" doesn't work)." >&2
    echo "Install the docker-compose-plugin package on the server, then run this again." >&2
    exit 1
    ;;
  *)
    echo "Couldn't check whether Docker works on the server. Carrying on, but if the" >&2
    echo "install fails at \"starting the stack\", check \"docker info\" works there." >&2
    ;;
esac
# Every pasted value is cleaned and checked before anything is written to the server.
# A paste that goes wrong is invisible: in Git Bash, Ctrl+V types a control character
# instead of pasting, and the installer used to save that one character as the
# OpenRouter key, so the chat only failed much later, with nothing to say why.
clean_value() { printf '%s' "$1" | LC_ALL=C tr -d '[:cntrl:][:space:]'; }
has_control_chars() { local LC_ALL=C; [[ "$1" =~ [[:cntrl:]] ]]; }
PASTE_HINT="In Git Bash, paste with right-click or Shift+Insert: Ctrl+V types an invisible character instead."

while :; do
  read -rp "Public subdomain (DNS must already point at that server's IP, e.g. chat.example.com): " SUBDOMAIN
  SUBDOMAIN="$(clean_value "$SUBDOMAIN")"
  SUBDOMAIN="${SUBDOMAIN#https://}"; SUBDOMAIN="${SUBDOMAIN#http://}"; SUBDOMAIN="${SUBDOMAIN%%/*}"
  case "$SUBDOMAIN" in *.*) break ;; esac
  echo "That doesn't look like a domain name. Enter just the name, e.g. chat.example.com" >&2
done
while :; do
  read -rp "Email for Let's Encrypt certificate notices: " LETSENCRYPT_EMAIL
  LETSENCRYPT_EMAIL="$(clean_value "$LETSENCRYPT_EMAIL")"
  case "$LETSENCRYPT_EMAIL" in ?*@?*.?*) break ;; esac
  echo "That doesn't look like an email address." >&2
done
echo
echo "OpenRouter (its own separate credential, not tied to Google auth)."
echo "Reminder: the account-wide training opt-out (paid/free models, separate toggles) is a"
echo "one-time manual step on https://openrouter.ai/settings/privacy, and this installer can't set it."
while :; do
  read -rp "OpenRouter API key: " OPENROUTER_KEY
  OPENROUTER_KEY="$(clean_value "$OPENROUTER_KEY")"
  if [ -z "$OPENROUTER_KEY" ]; then
    echo "Nothing came through. $PASTE_HINT" >&2
    continue
  fi
  # Ask OpenRouter whether the key works. The header is fed to curl on stdin, so the
  # key never appears in this computer's process list.
  OR_STATUS="$(printf 'Authorization: Bearer %s\n' "$OPENROUTER_KEY" \
    | curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H @- https://openrouter.ai/api/v1/key || true)"
  case "$OR_STATUS" in
    200) echo "OpenRouter accepted the key."; break ;;
    401|403)
      echo "OpenRouter rejected that key (${#OPENROUTER_KEY} characters received). Check you copied" >&2
      echo "all of it, then paste it again. $PASTE_HINT" >&2 ;;
    *) echo "Couldn't reach OpenRouter to check the key, so carrying on with it as entered." >&2; break ;;
  esac
done

echo
while :; do
  read -rp "Google OAuth Client ID (same one used for 'gmcp setup'): " GOOGLE_CLIENT_ID
  GOOGLE_CLIENT_ID="$(clean_value "$GOOGLE_CLIENT_ID")"
  if ! [[ "$GOOGLE_CLIENT_ID" =~ ^[0-9]+-[A-Za-z0-9_]+\.apps\.googleusercontent\.com$ ]]; then
    echo "That doesn't look like a Google OAuth Client ID, which ends in .apps.googleusercontent.com" >&2
    echo "(e.g. 123456789-abc123.apps.googleusercontent.com). $PASTE_HINT" >&2
    continue
  fi
  read -rp "Google OAuth Client Secret: " GOOGLE_CLIENT_SECRET
  GOOGLE_CLIENT_SECRET="$(clean_value "$GOOGLE_CLIENT_SECRET")"
  if [ -z "$GOOGLE_CLIENT_SECRET" ]; then
    echo "Nothing came through for the secret. $PASTE_HINT" >&2
    continue
  fi
  # Ask Google whether this ID and secret belong together, using a deliberately fake
  # sign-in code: a real client gets "invalid_grant" (bad code), a wrong ID or secret
  # gets "invalid_client". Nothing is created or changed on Google's side. (It can't
  # tell whether the redirect URI is registered: that's only checked at real sign-in.)
  G_REPLY="$(printf 'client_id=%s&client_secret=%s&grant_type=authorization_code&code=gmcp-installer-check&redirect_uri=https%%3A%%2F%%2F%s%%2Foauth%%2Fcallback' \
      "$GOOGLE_CLIENT_ID" "$GOOGLE_CLIENT_SECRET" "$SUBDOMAIN" \
    | curl -s --max-time 15 -H 'Content-Type: application/x-www-form-urlencoded' \
        --data-binary @- https://oauth2.googleapis.com/token || true)"
  case "$G_REPLY" in
    *invalid_grant*) echo "Google recognised the OAuth client."; break ;;
    *"client secret is invalid"*)
      echo "Google says that secret doesn't belong to that Client ID. Check you copied both from" >&2
      echo "the same OAuth client, then enter them again." >&2 ;;
    *invalid_client*)
      echo "Google doesn't know that Client ID. Check it's from your own OAuth client, then enter" >&2
      echo "it again." >&2 ;;
    *) echo "Couldn't confirm the OAuth client with Google, so carrying on with it as entered." >&2; break ;;
  esac
done

echo
echo "Your LibreChat login. Public signup stays disabled, because this server holds your Google"
echo "tokens, and every LibreChat user shares one gMCP credential, so anyone who could"
echo "register here would get your analytics data. This account is created directly instead."
while :; do
  read -rp "Your email: " ADMIN_EMAIL
  ADMIN_EMAIL="$(clean_value "$ADMIN_EMAIL")"
  case "$ADMIN_EMAIL" in ?*@?*.?*) break ;; esac
  echo "That doesn't look like an email address. It's what you'll sign in with." >&2
done
read -rp "Display name: " ADMIN_NAME
read -rp "Username: " ADMIN_USERNAME
while :; do
  read -rsp "Password: " ADMIN_PASSWORD
  echo
  if [ -z "$ADMIN_PASSWORD" ] || has_control_chars "$ADMIN_PASSWORD"; then
    echo "That password is empty or has an invisible character in it. $PASTE_HINT" >&2
    continue
  fi
  read -rsp "Password again: " ADMIN_PASSWORD_AGAIN
  echo
  [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_AGAIN" ] && break
  echo "Those didn't match. Try again." >&2
done
unset ADMIN_PASSWORD_AGAIN

# Runs on *your* machine, so it can't assume Linux. /proc/sys/kernel/random/uuid
# doesn't exist on Git Bash or macOS, and python3 on Windows is usually the
# Microsoft Store stub that prints an advert and fails. openssl is present in all
# three, so prefer it and fail loudly rather than generating an empty token.
local_random_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    echo "Need openssl (or uuidgen) on this machine to generate gMCP's access token." >&2
    return 1
  fi
}

GMCP_HTTP_TOKEN="$(grep -o '"token": *"[^"]*"' "$HOME/.gmcp/http_token.json" 2>/dev/null | grep -o '"[^"]*"$' | tr -d '"' || true)"
if [ -z "$GMCP_HTTP_TOKEN" ]; then
  GMCP_HTTP_TOKEN="$(local_random_token)"
fi
if [ -z "$GMCP_HTTP_TOKEN" ]; then
  echo "Could not generate gMCP's access token; aborting rather than deploying without one." >&2
  exit 1
fi

echo
echo "== Deploying to $SSH_TARGET =="

# Every ssh that doesn't stream input uses -n: without it, ssh reads whatever input is
# waiting (answers typed ahead, or piped in) and forwards it to the server, eating it.
#
# Many servers rate-limit SSH: DigitalOcean's Docker image allows about six new
# connections from one address in 30 seconds, then holds the rest back. The installer
# used to open well over that in bursts, so it stalled for minutes at a time. Every
# step below is batched into as few connections as possible; keep it that way.

# One connection copies the stack's files and reports back the server's home folder and
# this user's ids. The files are streamed through SSH as a tar into gmcp-server, which
# is relative to the home folder SSH starts in, so no separate mkdir or lookup is
# needed first. Deploying under the user's own home, rather than a hardcoded /root, is
# what lets a sudo user install.
echo "Copying installer files to the server…"
IFS='|' read -r REMOTE_HOME REMOTE_UID REMOTE_GID <<<"$(
  COPYFILE_DISABLE=1 tar -cf - -C "$SCRIPT_DIR" docker-compose.yml Caddyfile librechat.yaml .env.example rewrite_env.py \
    | ssh "$SSH_TARGET" 'mkdir -p gmcp-server/gmcp-data && tar -xf - -C gmcp-server && echo "$HOME|$(id -u)|$(id -g)"' \
    | tr -d '\r'
)"
if [ -z "$REMOTE_HOME" ] || [ -z "$REMOTE_UID" ]; then
  echo "Couldn't copy the installer files to the server over SSH." >&2
  exit 1
fi
REMOTE_DIR="$REMOTE_HOME/gmcp-server"

# Which uid the gmcp container runs as. Deploying as root, keep it on the image's own
# unprivileged user and chown the token store to match. The whole point is that the
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
if [ "$SEED_LOCAL_TOKENS" = true ]; then
  echo "Copying your existing Google sign-ins…"
  COPYFILE_DISABLE=1 tar -cf - -C "$HOME/.gmcp" token.json services.json \
    | ssh "$SSH_TARGET" "tar -xf - -C '$REMOTE_DIR/gmcp-data'"
fi

# The server's secrets, generated here rather than with one SSH connection each. They
# reach the server inside the connection's input, never on a command line.
random_hex() {
  local hex
  hex="$(openssl rand -hex "$1" 2>/dev/null || od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n')"
  if [ "${#hex}" -ne $(( $1 * 2 )) ]; then
    echo "Couldn't generate a random secret on this computer." >&2
    exit 1
  fi
  printf '%s' "$hex"
}
MEILI_MASTER_KEY="$(random_hex 16)"
ADMIN_PANEL_SESSION_SECRET="$(random_hex 16)"
CREDS_KEY="$(random_hex 32)"
CREDS_IV="$(random_hex 16)"
JWT_SECRET="$(random_hex 32)"
JWT_REFRESH_SECRET="$(random_hex 32)"

# One connection does all the setup on the server.
#
# .env.example already carries blank placeholder lines for most of these keys
# (SUBDOMAIN, OPENROUTER_KEY, GOOGLE_CLIENT_ID, CREDS_KEY, JWT_SECRET and so on):
# appending new lines instead of replacing them creates duplicate keys, and whichever
# value a given consumer's env-file parser picks first can silently differ from what's
# on the last line. rewrite_env.py does a real key=value replacement, reading the
# values from its input, so nothing has to be escaped into a shell or sed command.
#
# LibreChat, MongoDB and Meilisearch run as UID (the deploying user) and write into the
# bind-mounted data folders. Any that don't exist when the stack first starts are
# created by the Docker daemon, as root, and then nothing in the stack can write to
# them: on a non-root install MongoDB, Meilisearch and LibreChat all crash-loop on
# "permission denied". So they're created as the deploying user first. A run that
# already failed this way leaves them root-owned, which this user can't chown, but a
# throwaway container can (Docker access is root-equivalent anyway).
DATA_DIRS="data-node meili_data_v1.35.1 logs uploads images"
echo "Setting up the server…"
ssh "$SSH_TARGET" "bash -s" <<EOF
set -e
cd '$REMOTE_DIR'

# Google refresh tokens, if any were copied: owner-only, and owned by the user gmcp
# runs as (only possible, and only needed, when deploying as root).
chmod 700 gmcp-data
chmod 600 gmcp-data/*.json 2>/dev/null || true
if [ "$REMOTE_UID" = "0" ]; then chown -R $GMCP_UID:$GMCP_GID gmcp-data; fi

cp .env.example .env
python3 rewrite_env.py .env <<'ENVVALUES'
SUBDOMAIN=$SUBDOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
OPENROUTER_KEY=$OPENROUTER_KEY
GMCP_GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID
GMCP_GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET
GMCP_HTTP_TOKEN=$GMCP_HTTP_TOKEN
ALLOW_REGISTRATION=false
DOMAIN_CLIENT=https://$SUBDOMAIN
DOMAIN_SERVER=https://$SUBDOMAIN
MEILI_MASTER_KEY=$MEILI_MASTER_KEY
ADMIN_PANEL_SESSION_SECRET=$ADMIN_PANEL_SESSION_SECRET
CREDS_KEY=$CREDS_KEY
CREDS_IV=$CREDS_IV
JWT_SECRET=$JWT_SECRET
JWT_REFRESH_SECRET=$JWT_REFRESH_SECRET
UID=$REMOTE_UID
GID=$REMOTE_GID
GMCP_UID=$GMCP_UID
GMCP_GID=$GMCP_GID
ENVVALUES
# It now holds the OpenRouter key, Google client secret, gMCP's bearer token and
# LibreChat's JWT and encryption secrets, so it must not be world-readable.
chmod 600 .env

mkdir -p $DATA_DIRS
if [ "$REMOTE_UID" != "0" ] && [ -n "\$(find $DATA_DIRS -maxdepth 0 ! -user $REMOTE_UID)" ]; then
  echo "Handing data folders left over from an earlier run back to uid $REMOTE_UID…"
  docker run --rm -v "\$PWD":/w alpine:3 chown -R $REMOTE_UID:$REMOTE_GID $(for d in $DATA_DIRS; do printf '/w/%s ' "$d"; done)
fi
EOF
unset MEILI_MASTER_KEY ADMIN_PANEL_SESSION_SECRET CREDS_KEY CREDS_IV JWT_SECRET JWT_REFRESH_SECRET

echo "Pulling images and starting the stack (this takes a while the first time)…"
ssh -n "$SSH_TARGET" "cd '$REMOTE_DIR' && docker compose pull && docker compose up -d"

echo "Creating your LibreChat account…"
# Signup is disabled, so the first account is created directly against the running
# container, once LibreChat is ready. The wait happens on the server, inside this one
# connection: checking from here every few seconds would trip the SSH rate limit.
#
# The password is passed as an argument rather than over stdin. Piping it was the
# obvious choice, since create-user prompts for whatever it isn't given, but that
# silently does not work through ssh into `docker compose exec -T` into npm: the
# account gets created with a password that is not the one sent, so you can't log
# in and there's no error to tell you why. An argument is briefly visible in the
# server's process list, which on a single-tenant box you already have root on is
# a far smaller problem than an account nobody can access.
#
# It calls the script with node directly rather than `npm run create-user`, because
# npm prints the full command line it runs, password included, to the terminal.
# printf %q quotes each value for the server's shell, so a name like O'Neill, or a
# password containing quotes, arrives intact rather than breaking the command.
CREATE_ARGS="$(printf '%q ' "$ADMIN_EMAIL" "$ADMIN_NAME" "$ADMIN_USERNAME" "$ADMIN_PASSWORD")"
ssh -n "$SSH_TARGET" "cd '$REMOTE_DIR' \
  && for _ in \$(seq 1 60); do docker compose exec -T api test -f /app/config/create-user.js 2>/dev/null && break; sleep 5; done \
  && docker compose exec -T -w /app api node config/create-user.js $CREATE_ARGS--email-verified=true"
unset CREATE_ARGS

# Confirm the account actually works, rather than trusting "User created successfully".
# Checked from here over the public URL rather than on the server: LibreChat's port
# isn't published on the host (Caddy fronts it), so there's nothing to curl there.
# Retries because Caddy may still be obtaining its certificate.
echo "Checking you can log in…"
# Escaped for JSON (a password may contain " or \), and fed to curl on stdin so the
# password doesn't appear in this computer's process list.
json_escape() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
LOGIN_JSON="{\"email\":\"$(json_escape "$ADMIN_EMAIL")\",\"password\":\"$(json_escape "$ADMIN_PASSWORD")\"}"
LOGIN_OK=false
for _ in $(seq 1 20); do
  if printf '%s' "$LOGIN_JSON" | curl -sf -o /dev/null -X POST "https://$SUBDOMAIN/api/auth/login" \
      -H 'Content-Type: application/json' \
      --data-binary @- 2>/dev/null; then
    LOGIN_OK=true
    break
  fi
  sleep 10
done
if [ "$LOGIN_OK" = true ]; then
  echo "Verified: you can log in as $ADMIN_EMAIL."
else
  echo "NOTE: couldn't confirm login yet. If the certificate is still being issued this is" >&2
  echo "expected; try the site in a minute. If it persists, reset the password with:" >&2
  echo "  ssh $SSH_TARGET \"cd $REMOTE_DIR && docker compose exec api npm run reset-password\"" >&2
fi

echo
echo "Done. https://$SUBDOMAIN should be reachable once Caddy obtains its certificate"
echo "(check with: ssh $SSH_TARGET 'cd $REMOTE_DIR && docker compose logs -f caddy')."
echo "Sign in as $ADMIN_EMAIL. Public signup is off; add more people later with:"
echo "  ssh $SSH_TARGET \"cd $REMOTE_DIR && docker compose exec api npm run create-user\""

cat <<MSG

== Connecting your Google services ==

1. Add this to your Google OAuth client, exactly, under "Authorized redirect URIs"
   (console.cloud.google.com -> Google Auth Platform -> Clients -> your
   "Web application" client):

     https://$SUBDOMAIN/oauth/callback

2. Open your Connect page in any browser:

     https://$SUBDOMAIN/connect

   Unlock it with your gMCP access token:

     $GMCP_HTTP_TOKEN

   then click Connect next to each Google service you want, and approve it in the
   tab Google opens. Each one reaches your chat straight away, with no restart. Come
   back to the same page any time to add, reconnect or check a service.

Keep that token somewhere safe: it unlocks your Connect page, and it's also what any
other MCP client uses to reach https://$SUBDOMAIN/mcp.
MSG
