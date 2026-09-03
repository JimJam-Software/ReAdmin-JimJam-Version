#!/usr/bin/env bash
#
# ReAdmin single-VPS installer.
#
# Automates DEPLOY-VPS.md: swap, firewall, Docker, .env generation, build and
# start. Run it from a clone of this repository on a fresh Ubuntu/Debian box:
#
#     git clone https://github.com/JimJam-Software/ReAdmin-JimJam-Version.git /opt/readmin
#     cd /opt/readmin
#     sudo ./install.sh
#
# It is safe to re-run: every step checks whether it has already been done, and
# an existing .env is never overwritten without asking.
#
# Flags:
#   --skip-firewall   leave ufw alone (use if you manage the firewall elsewhere)
#   --skip-swap       never add a swapfile
#   --no-build        write .env and stop, without building or starting
#   --yes             assume yes for the "shall I proceed" confirmations
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PANEL_HOST="panel.jimadmin.costallogic.co"
API_HOST="api.jimadmin.costallogic.co"
CDN_HOST="cdn.jimadmin.costallogic.co"

SKIP_FIREWALL=0
SKIP_SWAP=0
NO_BUILD=0
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    --skip-firewall) SKIP_FIREWALL=1 ;;
    --skip-swap)     SKIP_SWAP=1 ;;
    --no-build)      NO_BUILD=1 ;;
    --yes|-y)        ASSUME_YES=1 ;;
    --help|-h)       sed -n '3,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- output ----

if [ -t 1 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'
else
  B=""; DIM=""; R=""; GRN=""; YEL=""; RED=""; CYN=""
fi

step()  { printf '\n%s==>%s %s%s%s\n' "$CYN" "$R" "$B" "$1" "$R"; }
ok()    { printf '  %s✓%s %s\n' "$GRN" "$R" "$1"; }
info()  { printf '  %s·%s %s\n' "$DIM" "$R" "$1"; }
warn()  { printf '  %s!%s %s\n' "$YEL" "$R" "$1"; }
die()   { printf '\n%serror:%s %s\n' "$RED" "$R" "$1" >&2; exit 1; }

# Prompts read from the terminal so that `curl ... | sudo bash` still works
# (there, stdin is the script itself). With no terminal at all — a CI run, a
# test harness — fall back to stdin so the script is still driveable.
# `[ -r /dev/tty ]` is true even when the device cannot actually be opened (a
# detached session, for instance), so try the open rather than stat it.
#
# The source is opened ONCE onto fd 3 and every prompt reads from that fd. A
# per-read redirect would re-open the source each time, and for a regular file
# that reopens at offset zero — so every prompt would return the first line.
if (exec 3</dev/tty) 2>/dev/null; then
  exec 3</dev/tty
else
  exec 3<&0
fi

confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local reply
  read -r -u 3 -p "  $1 [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# ------------------------------------------------------------ preflight -----

step "Checking the environment"

[ "$(id -u)" -eq 0 ] || die "Run this with sudo: sudo ./install.sh"
command -v apt-get >/dev/null 2>&1 || die "This installer expects a Debian or Ubuntu system (no apt-get found)."
[ -f "$REPO_DIR/docker-compose.yml" ] || die "Run this from inside the ReAdmin repository."

# The user we hand docker group membership to, since we are running as root.
TARGET_USER="${SUDO_USER:-root}"
ok "Running as root, target user is ${TARGET_USER}"

TOTAL_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
info "Detected ${TOTAL_MB} MB RAM"
if [ "$TOTAL_MB" -lt 3500 ]; then
  warn "Under 4 GB. The Next.js build is very likely to be killed even with swap."
  confirm "Continue anyway?" || exit 1
fi

step "Checking DNS"
DNS_OK=1
for host in "$PANEL_HOST" "$API_HOST" "$CDN_HOST"; do
  if getent hosts "$host" >/dev/null 2>&1; then
    ok "$host resolves"
  else
    warn "$host does not resolve yet"
    DNS_OK=0
  fi
done
if [ "$DNS_OK" = "0" ]; then
  warn "Caddy requests Let's Encrypt certificates on boot. Names that do not"
  warn "resolve will fail, and repeated failures get the domain rate-limited."
  confirm "Carry on regardless?" || die "Add the A records, then re-run this script."
fi

# ----------------------------------------------------------------- swap -----

step "Swap"
SWAP_MB=$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$SKIP_SWAP" = "1" ]; then
  info "Skipped (--skip-swap)"
elif [ "$TOTAL_MB" -ge 7500 ]; then
  ok "${TOTAL_MB} MB RAM, no swap needed"
elif [ "$SWAP_MB" -ge 2000 ]; then
  ok "${SWAP_MB} MB of swap already present"
elif [ -f /swapfile ]; then
  warn "/swapfile exists but is not active; leaving it alone"
else
  info "Creating a 4 GB swapfile so the build has headroom"
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  ok "Swap active and recorded in /etc/fstab"
fi

# ------------------------------------------------------------- firewall -----

step "Firewall"
if [ "$SKIP_FIREWALL" = "1" ]; then
  info "Skipped (--skip-firewall)"
else
  if ! command -v ufw >/dev/null 2>&1; then
    info "Installing ufw"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null
  fi
  # Order matters: SSH is allowed before the policy flips to deny, otherwise
  # enabling ufw over SSH locks you out of the machine.
  ufw allow 22/tcp  >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  ok "ufw allows 22, 80, 443 and denies everything else inbound"
  info "Note: Docker's own iptables rules bypass ufw. Only Caddy publishes ports here."
fi

# --------------------------------------------------------------- docker -----

step "Docker"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker and the compose plugin are already installed"
else
  info "Installing Docker from get.docker.com"
  curl -fsSL https://get.docker.com | sh
  ok "Docker installed"
fi

if [ "$TARGET_USER" != "root" ]; then
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
    ok "${TARGET_USER} is already in the docker group"
  else
    usermod -aG docker "$TARGET_USER"
    ok "Added ${TARGET_USER} to the docker group"
    warn "${TARGET_USER} must log out and back in before running docker unsudoed."
  fi
fi

systemctl enable --now docker >/dev/null 2>&1 || true

# ------------------------------------------------------------------ env -----

step "Environment file"

ENV_FILE="$REPO_DIR/.env"
EXAMPLE_FILE="$REPO_DIR/.env.example"
[ -f "$EXAMPLE_FILE" ] || die ".env.example is missing from the repository."

WRITE_ENV=1
if [ -f "$ENV_FILE" ]; then
  warn ".env already exists."
  if confirm "Keep it and skip straight to the build?"; then
    WRITE_ENV=0
    ok "Keeping the existing .env"
  else
    BACKUP="$ENV_FILE.backup.$(date +%Y%m%d%H%M%S)"
    cp "$ENV_FILE" "$BACKUP"
    chmod 600 "$BACKUP"
    ok "Backed the old one up to $(basename "$BACKUP")"
  fi
fi

declare -A VALS

# A closed input (EOF) is fatal for a required value and would otherwise spin
# forever on "Required." — so say what happened and stop.
ask() { # ask VAR "Prompt" [secret]
  local var="$1" prompt="$2" secret="${3:-}" input="" rc=0
  while [ -z "$input" ]; do
    if [ -n "$secret" ]; then
      read -r -u 3 -s -p "  ${prompt}: " input || rc=$?; echo
    else
      read -r -u 3 -p "  ${prompt}: " input || rc=$?
    fi
    if [ "$rc" -ne 0 ] && [ -z "$input" ]; then
      die "Input ended while waiting for ${var}. Run the script from a terminal, or pipe an answer for every prompt."
    fi
    [ -z "$input" ] && warn "Required."
  done
  VALS["$var"]="$input"
}

# EOF here just means "no value given", which is a legitimate answer.
ask_optional() { # ask_optional VAR "Prompt"
  local var="$1" prompt="$2" input=""
  read -r -u 3 -p "  ${prompt} (blank to skip): " input || true
  VALS["$var"]="$input"
}

if [ "$WRITE_ENV" = "1" ]; then
  echo
  info "Generating secrets"
  # CRYPTO_KEY is used verbatim as an AES-256-CBC key and must be exactly 32
  # characters — 16 hex bytes renders as 32 chars.
  VALS[CRYPTO_KEY]="$(openssl rand -hex 16)"
  VALS[JSON_WEB_TOKEN_SECRET]="$(openssl rand -hex 32)"
  VALS[MONGO_ROOT_USER]="readmin"
  VALS[MONGO_ROOT_PASSWORD]="$(openssl rand -hex 24)"
  VALS[CDN_ACCESS_KEY_ID]="readmin-$(openssl rand -hex 6)"
  VALS[CDN_SECRET_ACCESS_KEY]="$(openssl rand -hex 20)"
  # Hex only, so nothing here needs URL-escaping inside the connection string.
  VALS[MONGODB_URI]="mongodb://${VALS[MONGO_ROOT_USER]}:${VALS[MONGO_ROOT_PASSWORD]}@mongo:27017/?authSource=admin"
  ok "CRYPTO_KEY (${#VALS[CRYPTO_KEY]} chars), JWT secret, Mongo and MinIO credentials"

  echo
  printf '  %sCredentials you have to supply.%s Secrets are not echoed.\n' "$B" "$R"
  printf '  %sSee README §2 for where each of these comes from.%s\n\n' "$DIM" "$R"

  ask          ACME_EMAIL            "Email for Let's Encrypt expiry notices"
  echo
  ask          ROBLOX_CLIENT_ID      "Roblox OAuth client ID"
  ask          ROBLOX_CLIENT_SECRET  "Roblox OAuth client secret" secret
  ask          ROBLOX_API_KEY        "Roblox Open Cloud API key"  secret
  ask          ROBLOX_COOKIE         "Roblox account cookie (.ROBLOSECURITY)" secret
  ask          ROBLOX_USER_ID        "Roblox user ID of that account"
  echo
  ask          DISCORD_CLIENT_ID     "Discord application client ID"
  ask          DISCORD_CLIENT_SECRET "Discord client secret" secret
  ask          DISCORD_TOKEN         "Discord bot token"     secret
  ask          DISCORD_PUBLIC_KEY    "Discord public key"
  echo
  ask          BLOXLINK_TOKEN        "Bloxlink API v4 token" secret
  echo
  ask_optional AIKIDO_TOKEN          "Aikido Zen token (AIK_RUNTIME_...)"

  # Mirrored into the browser bundle at build time.
  VALS[NEXT_PUBLIC_ROBLOX_CLIENT_ID]="${VALS[ROBLOX_CLIENT_ID]}"
  VALS[NEXT_PUBLIC_DISCORD_CLIENT_ID]="${VALS[DISCORD_CLIENT_ID]}"

  # Rewrite .env.example line by line, substituting the values we hold and
  # uncommenting the keys we are setting. Done in bash rather than sed so that
  # slashes and pipes in tokens and cookies cannot corrupt the output.
  : >"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  declare -A WRITTEN
  while IFS= read -r line || [ -n "$line" ]; do
    key=""
    if [[ "$line" =~ ^#?[[:space:]]*([A-Z][A-Z0-9_]*)= ]]; then
      key="${BASH_REMATCH[1]}"
    fi
    if [ -n "$key" ] && [ -n "${VALS[$key]+set}" ] && [ -z "${WRITTEN[$key]+set}" ]; then
      if [ -n "${VALS[$key]}" ]; then
        printf '%s=%s\n' "$key" "${VALS[$key]}" >>"$ENV_FILE"
      else
        printf '# %s=\n' "$key" >>"$ENV_FILE"
      fi
      WRITTEN[$key]=1
    else
      printf '%s\n' "$line" >>"$ENV_FILE"
    fi
  done <"$EXAMPLE_FILE"

  # Anything the example did not mention (MONGO_ROOT_* live only in compose).
  EXTRA=""
  for key in "${!VALS[@]}"; do
    if [ -z "${WRITTEN[$key]+set}" ] && [ -n "${VALS[$key]}" ]; then
      EXTRA+="$(printf '%s=%s\n' "$key" "${VALS[$key]}")"$'\n'
    fi
  done
  if [ -n "$EXTRA" ]; then
    { echo; echo "# --- added by install.sh ---"; printf '%s' "$EXTRA"; } >>"$ENV_FILE"
  fi

  ok "Wrote .env (mode 600, owned by root)"
  warn "Back up .env off this machine. Losing CRYPTO_KEY makes every stored OAuth token unreadable."
fi

# ---------------------------------------------------------------- build -----

if [ "$NO_BUILD" = "1" ]; then
  step "Stopping before the build (--no-build)"
  info "Review .env, then run: docker compose build && docker compose up -d"
  exit 0
fi

step "Building"
info "This takes a while — longer on swap. Next validates the whole environment here."
cd "$REPO_DIR"
docker compose build

step "Starting"
docker compose up -d
ok "Containers started"

# minio-init creates the bucket and exits, so it is expected to be absent from
# the running set. Give the app containers a moment before health checking.
step "Waiting for the panel and API"
HEALTHY=0
for _ in $(seq 1 60); do
  if curl -sf -o /dev/null http://localhost:3000/api/health 2>/dev/null \
     || docker compose exec -T panel node -e "fetch('http://localhost:3000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    HEALTHY=1
    break
  fi
  sleep 5
done

if [ "$HEALTHY" = "1" ]; then
  ok "Panel is answering its health check"
else
  warn "Panel did not answer within five minutes. Check: docker compose logs panel"
fi

step "Done"
cat <<EOF

  Panel   https://${PANEL_HOST}
  API     https://${API_HOST}
  Storage https://${CDN_HOST}

  Certificates are issued on first request and can take a minute.

  Next:
    1. curl https://${PANEL_HOST}/api/health
    2. Log in through the panel — that proves Roblox OAuth, Mongo and the
       JWT secret are all correct at once.
    3. Set up backups            — DEPLOY-VPS.md §9
    4. Republish the Roblox modules — DEPLOY-VPS.md §12. Skip this and the
       panel works while nothing in-game is ever recorded.

  Logs:    docker compose logs -f panel api sync
  Status:  docker compose ps

EOF
