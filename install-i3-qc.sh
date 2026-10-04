#!/usr/bin/env bash
# =====================
# FILE: install-i3-qc.sh
# AUTHOR: Dan Eckert (deckert@troyergroup.com)
# DESCRIPTION: Installs, upgrades, rolls back or removes the I3 Design QC App on Ubuntu 24.04 (Node.js, systemd, nginx). Safe to re-run: each run builds a new release and keeps older ones for rollback.
# DATE: 2026-10-04 @ 09:50 (EST)
# VERSION: 1.0
# NOTE: Dependencies detected: [nodejs (NodeSource), nginx, openssl, rsync, curl, gnupg, apache2-utils, util-linux (flock, runuser), ufw (optional)]
# =====================
#
# Usage: sudo ./deploy/install-i3-qc.sh [install|rollback|status|uninstall] [options]
# Help:  ./deploy/install-i3-qc.sh --help
# This file must keep LF line endings (see .gitattributes) and plain ASCII.

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# ---------------------------------------------------------------------------
# Fixed layout (the deployment contract shared with the app and DEPLOY.md)
# ---------------------------------------------------------------------------
readonly APP_NAME="i3-qc"
readonly APP_USER="i3qc"
readonly APP_GROUP="i3qc"
readonly INSTALL_ROOT="/opt/i3-qc"
readonly RELEASES_DIR="$INSTALL_ROOT/releases"
readonly CURRENT_LINK="$INSTALL_ROOT/current"
readonly PREVIOUS_LINK="$INSTALL_ROOT/previous"
readonly CONF_DIR="/etc/i3-qc"
readonly ENV_FILE="$CONF_DIR/i3-qc.env"
readonly STATE_DIR="/var/lib/i3-qc"
readonly UNIT_FILE="/etc/systemd/system/i3-qc.service"
readonly NGINX_SITE="/etc/nginx/sites-available/i3-qc.conf"
readonly NGINX_LINK="/etc/nginx/sites-enabled/i3-qc.conf"
readonly HTPASSWD_FILE="/etc/nginx/i3-qc.htpasswd"
readonly TLS_DIR="/etc/ssl/i3-qc"
readonly LOG_FILE="/var/log/i3-qc-install.log"
readonly LOCK_FILE="/var/lock/i3-qc-install.lock"
readonly BACKEND_ENTRY="src/server.js"

# ---------------------------------------------------------------------------
# Options (ARG_* = given on the command line; the rest are resolved later)
# ---------------------------------------------------------------------------
COMMAND="install"
SOURCE_DIR=""
ARG_SERVER_NAME=""
ARG_PROJECTS_ROOT=""
ARG_PORT=""
NODE_MAJOR="24"
TLS_MODE="selfsigned"
TLS_CERT=""
TLS_KEY=""
AUTH_MODE="basic"
AUTH_USER="qcuser"
RESET_AUTH=0
ALLOW_CIDRS=()
CONFIGURE_FIREWALL=0
KEEP_RELEASES=3
FORCE_REBUILD=0
FORCE_OS=0
PURGE=0
ASSUME_YES=0

# Resolved settings
SERVER_NAME=""
PROJECTS_ROOT=""
PORT=""
NODE_BIN=""
CERT_PATH=""
KEY_PATH=""

# Run state
CHANGED=0
FILE_CHANGED=0
RELEASE_ID=""
GENERATED_PASSWORD=""
BUILD_DIR=""
SMOKE_PID=""
PROBE_MODE=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '%s [i3-qc] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [i3-qc] WARNING: %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { trap - ERR; printf '%s [i3-qc] ERROR: %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

cleanup() {
  local rc=$?
  if [[ -n "$SMOKE_PID" ]] && kill -0 "$SMOKE_PID" 2>/dev/null; then
    kill "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
  fi
  if [[ "$BUILD_DIR" == /tmp/i3-qc-build.* && -d "$BUILD_DIR" ]]; then
    rm -rf -- "$BUILD_DIR"
  fi
  return "$rc"
}

usage() {
  cat <<'EOF'
I3 Design QC App - installer for Ubuntu 24.04

Usage: sudo ./deploy/install-i3-qc.sh [command] [options]

Commands:
  install      Install or upgrade (default). Idempotent: safe to run again.
  rollback     Switch back to the previous release and restart the service.
  status       Show release, service, health and certificate information.
  uninstall    Remove service, nginx site and releases (needs --yes).
               Config, state and project data are kept unless --purge is given
               (--purge never touches the projects root).

Install options:
  --source DIR            Repo checkout to deploy (default: parent of this script)
  --server-name NAME      Host name or IP users will browse to (default: this host's FQDN)
  --projects-root DIR     Folder holding ArcGIS project folders (default: /srv/i3-projects)
  --port N                Backend loopback port (default: 4000)
  --node-major N          Node.js major version to install (default: 24)
  --tls MODE              selfsigned (default) | provided | none
  --cert FILE --key FILE  Certificate and key to use with --tls provided
  --auth-user NAME        nginx basic-auth user (default: qcuser)
  --no-auth               Do not require a login (only sensible with --allow-cidr)
  --reset-auth            Regenerate the basic-auth password
  --allow-cidr CIDR       Only allow this network (repeatable), e.g. 10.20.0.0/16
  --configure-firewall    Install/enable ufw allowing SSH, 80 and 443
  --keep-releases N       Releases to keep for rollback (default: 3)
  --force-rebuild         Build a new release even if the source is unchanged
  --force-os              Run on a distro other than Ubuntu 24.04
  --yes                   Confirm destructive commands (uninstall)
  --purge                 With uninstall: also delete /etc/i3-qc, /var/lib/i3-qc, certs

Environment:
  I3QC_AUTH_PASSWORD      Use this password instead of a generated one

Examples:
  sudo ./deploy/install-i3-qc.sh --server-name qc.example.com --allow-cidr 10.20.0.0/16
  sudo ./deploy/install-i3-qc.sh status
  sudo ./deploy/install-i3-qc.sh rollback
EOF
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    case "$1" in
      install|rollback|status|uninstall) COMMAND="$1"; shift ;;
      *) ;;
    esac
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)             SOURCE_DIR="${2:?--source needs a value}"; shift 2 ;;
      --server-name)        ARG_SERVER_NAME="${2:?--server-name needs a value}"; shift 2 ;;
      --projects-root)      ARG_PROJECTS_ROOT="${2:?--projects-root needs a value}"; shift 2 ;;
      --port)               ARG_PORT="${2:?--port needs a value}"; shift 2 ;;
      --node-major)         NODE_MAJOR="${2:?--node-major needs a value}"; shift 2 ;;
      --tls)                TLS_MODE="${2:?--tls needs a value}"; shift 2 ;;
      --cert)               TLS_CERT="${2:?--cert needs a value}"; shift 2 ;;
      --key)                TLS_KEY="${2:?--key needs a value}"; shift 2 ;;
      --auth-user)          AUTH_USER="${2:?--auth-user needs a value}"; shift 2 ;;
      --no-auth)            AUTH_MODE="none"; shift ;;
      --reset-auth)         RESET_AUTH=1; shift ;;
      --allow-cidr)         ALLOW_CIDRS+=("${2:?--allow-cidr needs a value}"); shift 2 ;;
      --configure-firewall) CONFIGURE_FIREWALL=1; shift ;;
      --keep-releases)      KEEP_RELEASES="${2:?--keep-releases needs a value}"; shift 2 ;;
      --force-rebuild)      FORCE_REBUILD=1; shift ;;
      --force-os)           FORCE_OS=1; shift ;;
      --purge)              PURGE=1; shift ;;
      --yes)                ASSUME_YES=1; shift ;;
      -h|--help)            usage; exit 0 ;;
      *)                    die "Unknown option: $1 (try --help)" ;;
    esac
  done
}

validate_options() {
  local c
  [[ -z "$ARG_PORT" || "$ARG_PORT" =~ ^[0-9]{4,5}$ ]] || die "--port must be a number between 1024 and 65535"
  if [[ -n "$ARG_PORT" ]] && (( ARG_PORT < 1024 || ARG_PORT > 65535 )); then die "--port must be between 1024 and 65535"; fi
  [[ "$NODE_MAJOR" =~ ^[0-9]{2}$ ]] || die "--node-major must be a 2-digit major version such as 24"
  [[ "$KEEP_RELEASES" =~ ^[0-9]+$ ]] || die "--keep-releases must be a number >= 2"
  if (( KEEP_RELEASES < 2 )); then die "--keep-releases must be a number >= 2"; fi
  [[ -z "$ARG_SERVER_NAME" || "$ARG_SERVER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "--server-name may contain only letters, digits, dot, underscore and hyphen"
  [[ -z "$ARG_PROJECTS_ROOT" || "$ARG_PROJECTS_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "--projects-root must be an absolute path without spaces or special characters"
  [[ "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]] || die "--auth-user may contain only letters, digits, dot, underscore and hyphen"
  case "$TLS_MODE" in
    selfsigned|none) ;;
    provided)
      [[ -r "$TLS_CERT" && -r "$TLS_KEY" ]] || die "--tls provided needs readable --cert and --key files" ;;
    *) die "--tls must be selfsigned, provided or none" ;;
  esac
  for c in "${ALLOW_CIDRS[@]}"; do
    [[ "$c" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || die "Invalid --allow-cidr value: $c"
  done
  if [[ "$AUTH_MODE" == "none" && ${#ALLOW_CIDRS[@]} -eq 0 && "$COMMAND" == "install" ]]; then
    warn "--no-auth without --allow-cidr leaves the app open to anyone who can reach this server"
  fi
}

require_root() { [[ $EUID -eq 0 ]] || die "Run as root: sudo $0 $*"; }

check_os() {
  local os_id os_ver
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
  os_ver="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
  if [[ "$os_id" != "ubuntu" || "$os_ver" != "24.04" ]]; then
    if (( FORCE_OS )); then
      warn "Untested OS ($os_id $os_ver); continuing because of --force-os"
    else
      die "This installer targets Ubuntu 24.04 (found $os_id $os_ver). Use --force-os to try anyway."
    fi
  fi
  command -v systemctl >/dev/null 2>&1 || die "systemd is required"
  [[ -d /run/systemd/system ]] || die "systemd is not running as PID 1 (on WSL2 set systemd=true in /etc/wsl.conf and restart the distro)"
}

as_app() { runuser -u "$APP_USER" -- env HOME="$STATE_DIR" npm_config_cache="$STATE_DIR/.npm" "$@"; }
as_app_in() { local dir="$1"; shift; ( cd "$dir" && as_app "$@" ); }

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

env_set() {
  local key="$1" val="$2" cur
  cur="$(env_get "$key")"
  [[ "$cur" == "$val" ]] && return 0
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >>"$ENV_FILE"
  fi
  CHANGED=1
}

# Reads new content on stdin; writes DEST only when it differs. Sets FILE_CHANGED.
# Call it as: write_managed_file DEST MODE < <(generator)   (not through a pipe)
write_managed_file() {
  local dest="$1" mode="$2" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    FILE_CHANGED=0
  else
    install -D -m "$mode" -o root -g root "$tmp" "$dest"
    FILE_CHANGED=1
  fi
  rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
# A broken third-party apt source must not abort the install; installs below still fail loudly if needed.
apt_update() {
  if ! apt-get update -qq; then warn "apt-get update reported errors (check /etc/apt/sources.list.d); continuing"; fi
}

install_packages() {
  local pkgs=(ca-certificates curl gnupg rsync openssl nginx)
  if [[ "$AUTH_MODE" == "basic" ]]; then pkgs+=(apache2-utils); fi
  log "Installing OS packages: ${pkgs[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get install -y -qq --no-install-recommends "${pkgs[@]}"
}

node_major_installed() {
  if command -v node >/dev/null 2>&1; then
    node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
  else
    echo 0
  fi
}

install_node() {
  local have
  have="$(node_major_installed)"
  if (( have >= NODE_MAJOR )); then
    log "Node.js $(node -v) already installed (need >= $NODE_MAJOR)"
    NODE_BIN="$(command -v node)"
    return 0
  fi
  log "Installing Node.js ${NODE_MAJOR}.x from NodeSource (found: v${have})"
  if pkg_installed npm; then
    die "Ubuntu's 'npm' package is installed and conflicts with NodeSource Node.js. Run: apt-get remove -y npm nodejs libnode-dev  then re-run this script."
  fi
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
  printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' "$NODE_MAJOR" >/etc/apt/sources.list.d/nodesource.list
  apt_update
  apt-get install -y -qq nodejs
  have="$(node_major_installed)"
  (( have >= NODE_MAJOR )) || die "Node.js install did not reach v${NODE_MAJOR} (found v${have})"
  NODE_BIN="$(command -v node)"
  CHANGED=1
  log "Node.js $(node -v) installed"
}

ensure_user() {
  if ! getent group "$APP_GROUP" >/dev/null; then groupadd --system "$APP_GROUP"; fi
  if ! id -u "$APP_USER" >/dev/null 2>&1; then
    useradd --system --gid "$APP_GROUP" --home-dir "$STATE_DIR" --no-create-home \
      --shell /usr/sbin/nologin --comment "I3 Design QC App" "$APP_USER"
    log "Created service account $APP_USER"
  fi
}

resolve_settings() {
  local v
  PORT="$ARG_PORT"
  if [[ -z "$PORT" ]]; then v="$(env_get PORT)"; PORT="${v:-4000}"; fi
  PROJECTS_ROOT="$ARG_PROJECTS_ROOT"
  if [[ -z "$PROJECTS_ROOT" ]]; then v="$(env_get I3QC_PROJECTS_ROOT)"; PROJECTS_ROOT="${v:-/srv/i3-projects}"; fi
  SERVER_NAME="$ARG_SERVER_NAME"
  if [[ -z "$SERVER_NAME" ]]; then
    v="$(env_get I3QC_ALLOWED_ORIGINS)"; v="${v%%,*}"; v="${v#*://}"; v="${v%%[:/]*}"
    SERVER_NAME="${v:-$(hostname -f 2>/dev/null || hostname)}"
  fi
  [[ "$PORT" =~ ^[0-9]{4,5}$ ]] || die "Invalid port in $ENV_FILE: $PORT"
  [[ "$PROJECTS_ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "Invalid I3QC_PROJECTS_ROOT: $PROJECTS_ROOT"
  [[ "$SERVER_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid server name: $SERVER_NAME (use --server-name)"
  if [[ "$SERVER_NAME" != *.* && ! "$SERVER_NAME" =~ ^[0-9.]+$ ]]; then
    warn "Server name '$SERVER_NAME' is a single label; pass --server-name with the FQDN or IP users will type"
  fi
}

ensure_dirs() {
  install -d -m 0755 -o root -g root "$INSTALL_ROOT" "$RELEASES_DIR"
  install -d -m 0750 -o "$APP_USER" -g "$APP_GROUP" "$STATE_DIR"
  install -d -m 0750 -o root -g "$APP_GROUP" "$CONF_DIR"
  if [[ ! -d "$PROJECTS_ROOT" ]]; then
    install -d -m 2775 -o "$APP_USER" -g "$APP_GROUP" "$PROJECTS_ROOT"
    log "Created projects root $PROJECTS_ROOT (group-writable, setgid)"
  elif ! runuser -u "$APP_USER" -- test -r "$PROJECTS_ROOT" -a -x "$PROJECTS_ROOT"; then
    warn "Service user '$APP_USER' cannot read $PROJECTS_ROOT; fix ownership or mount options (uid/gid)"
  elif ! runuser -u "$APP_USER" -- test -w "$PROJECTS_ROOT"; then
    warn "Service user '$APP_USER' cannot write to $PROJECTS_ROOT; workbook push and qc-overrides need write access"
  fi
}

write_env_file() {
  local origin
  if [[ "$TLS_MODE" == "none" ]]; then origin="http://$SERVER_NAME"; else origin="https://$SERVER_NAME"; fi
  if [[ ! -f "$ENV_FILE" ]]; then
    cat >"$ENV_FILE" <<EOF
# I3 Design QC App runtime settings (read by systemd).
# After editing run: sudo systemctl restart i3-qc
NODE_ENV=production
HOST=127.0.0.1
PORT=$PORT
I3QC_PROJECTS_ROOT=$PROJECTS_ROOT
I3QC_STATE_DIR=$STATE_DIR
I3QC_TRUST_PROXY=1
I3QC_ALLOWED_ORIGINS=$origin
I3QC_SESSION_TTL_MINUTES=120
I3QC_ALLOW_WORKBOOK_PUSH=true
I3QC_LOG_LEVEL=info
# Raise the V8 heap limit (MB) on a larger server, if needed:
#NODE_OPTIONS=--max-old-space-size=2048
EOF
    chown root:"$APP_GROUP" "$ENV_FILE"
    chmod 0640 "$ENV_FILE"
    CHANGED=1
    log "Wrote $ENV_FILE"
    return 0
  fi
  log "Keeping existing $ENV_FILE (explicit options below update only their own keys)"
  if [[ -n "$ARG_PORT" ]]; then env_set PORT "$ARG_PORT"; fi
  if [[ -n "$ARG_PROJECTS_ROOT" ]]; then env_set I3QC_PROJECTS_ROOT "$ARG_PROJECTS_ROOT"; fi
  if [[ -n "$ARG_SERVER_NAME" ]]; then env_set I3QC_ALLOWED_ORIGINS "$origin"; fi
}

compute_source_hash() {
  (
    cd "$SOURCE_DIR"
    find . \( -name .git -o -name node_modules -o -name dist -o -name qc-overrides -o -path ./deploy -o -path ./scripts \) -prune -o \
      -type f ! -name project.config.json ! -name '*.log' ! -name '.env' ! -name '.DS_Store' -print0 \
      | LC_ALL=C sort -z | xargs -0 -r sha256sum | sha256sum | cut -d' ' -f1
  )
}

resolve_source() {
  if [[ -z "$SOURCE_DIR" ]]; then SOURCE_DIR="$(dirname "$SCRIPT_DIR")"; fi
  SOURCE_DIR="$(readlink -f "$SOURCE_DIR")"
  [[ -f "$SOURCE_DIR/backend/package.json" ]]            || die "backend/package.json not found under $SOURCE_DIR (use --source DIR)"
  [[ -f "$SOURCE_DIR/frontend/package.json" ]]           || die "frontend/package.json not found under $SOURCE_DIR (use --source DIR)"
  [[ -f "$SOURCE_DIR/backend/$BACKEND_ENTRY" ]]          || die "backend/$BACKEND_ENTRY not found under $SOURCE_DIR"
}

npm_deps() {
  local dir="$1"; shift
  if [[ -f "$dir/package-lock.json" ]]; then
    if ! as_app_in "$dir" npm ci --no-audit --no-fund "$@"; then
      warn "npm ci failed in $dir (lockfile out of sync?); falling back to npm install"
      as_app_in "$dir" npm install --no-audit --no-fund "$@"
    fi
  else
    warn "No package-lock.json in $dir; using npm install (not reproducible)"
    as_app_in "$dir" npm install --no-audit --no-fund "$@"
  fi
}

free_port() {
  node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close();});'
}

# probe_app BASE_URL [TRIES]: prefers /api/healthz, falls back to / with a warning
probe_app() {
  local base="$1" tries="${2:-30}" i
  PROBE_MODE=""
  for ((i = 1; i <= tries; i++)); do
    if curl -fsS -o /dev/null --max-time 3 "$base/api/healthz" 2>/dev/null; then PROBE_MODE="healthz"; return 0; fi
    if curl -fsS -o /dev/null --max-time 3 "$base/" 2>/dev/null; then PROBE_MODE="root"; return 0; fi
    sleep 1
  done
  return 1
}

smoke_test_release() {
  local rel="$1" port tmp
  port="$(free_port)"
  tmp="$(mktemp -d /tmp/i3-qc-smoke.XXXXXX)"
  mkdir -p "$tmp/projects" "$tmp/state"
  chown -R "$APP_USER:$APP_GROUP" "$tmp"
  log "Smoke-testing new release on 127.0.0.1:$port before switching"
  (
    cd "$rel/backend"
    exec timeout 60 runuser -u "$APP_USER" -- env NODE_ENV=production HOST=127.0.0.1 PORT="$port" \
      I3QC_PROJECTS_ROOT="$tmp/projects" I3QC_STATE_DIR="$tmp/state" "$NODE_BIN" "$BACKEND_ENTRY"
  ) >"$tmp/smoke.log" 2>&1 &
  SMOKE_PID=$!
  if ! probe_app "http://127.0.0.1:$port" 30; then
    warn "Smoke test failed; last log lines:"
    tail -n 30 "$tmp/smoke.log" >&2 || true
    kill "$SMOKE_PID" 2>/dev/null || true
    rm -rf -- "$tmp" "$rel"
    die "New release failed its smoke test and was discarded; the current release is untouched"
  fi
  if [[ "$PROBE_MODE" == "root" ]]; then
    warn "GET /api/healthz is not answering; passed on GET / only (the app should implement /api/healthz)"
  fi
  kill "$SMOKE_PID" 2>/dev/null || true
  wait "$SMOKE_PID" 2>/dev/null || true
  SMOKE_PID=""
  rm -rf -- "$tmp"
  log "Smoke test passed"
}

point_link() {  # point_link LINK TARGET : atomic symlink swap
  ln -sfn "$2" "$1.new"
  mv -Tf "$1.new" "$1"
}

# After discarding a bad release: point "previous" at the newest remaining release that is not current.
repoint_previous() {
  local cur d newprev=""
  cur="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  while IFS= read -r d; do
    if [[ "$d" != "$cur" ]]; then newprev="$d"; break; fi
  done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort -r)
  if [[ -n "$newprev" ]]; then point_link "$PREVIOUS_LINK" "$newprev"; else rm -f "$PREVIOUS_LINK"; fi
}

switch_release() {
  local rel="$1" prev=""
  if [[ -L "$CURRENT_LINK" ]]; then prev="$(readlink -f "$CURRENT_LINK")"; fi
  if [[ -n "$prev" && "$prev" != "$rel" ]]; then point_link "$PREVIOUS_LINK" "$prev"; fi
  point_link "$CURRENT_LINK" "$rel"
  CHANGED=1
  log "Current release is now $(basename "$rel")"
}

build_release() {
  local hash cur_hash="" rel sha=""
  hash="$(compute_source_hash)"
  if [[ -f "$CURRENT_LINK/.source-hash" ]]; then cur_hash="$(cat "$CURRENT_LINK/.source-hash")"; fi
  if (( ! FORCE_REBUILD )) && [[ -n "$hash" && "$hash" == "$cur_hash" ]]; then
    log "Source unchanged since the current release; skipping build (use --force-rebuild to override)"
    return 0
  fi

  RELEASE_ID="$(date +%Y%m%d-%H%M%S)"
  rel="$RELEASES_DIR/$RELEASE_ID"
  BUILD_DIR="$(mktemp -d /tmp/i3-qc-build.XXXXXX)"
  chmod 0700 "$BUILD_DIR"

  log "Copying source to a temporary build directory"
  rsync -a --exclude=.git/ --exclude=node_modules/ --exclude=dist/ --exclude=qc-overrides/ \
    --exclude=project.config.json --exclude='*.log' --exclude=.env --exclude=.DS_Store \
    "$SOURCE_DIR"/ "$BUILD_DIR"/
  chown -R "$APP_USER:$APP_GROUP" "$BUILD_DIR"

  log "Installing backend dependencies (production only)"
  npm_deps "$BUILD_DIR/backend" --omit=dev
  log "Installing frontend dependencies and building"
  npm_deps "$BUILD_DIR/frontend"
  as_app_in "$BUILD_DIR/frontend" npm run build
  [[ -f "$BUILD_DIR/frontend/dist/index.html" ]] || die "Frontend build produced no dist/index.html"

  log "Staging release $RELEASE_ID"
  install -d -m 0755 "$rel" "$rel/backend" "$rel/frontend/dist"
  rsync -a "$BUILD_DIR/backend/" "$rel/backend/"
  rsync -a "$BUILD_DIR/frontend/dist/" "$rel/frontend/dist/"
  if command -v git >/dev/null 2>&1; then sha="$(git -C "$SOURCE_DIR" rev-parse --short HEAD 2>/dev/null || true)"; fi
  printf 'release=%s\ncommit=%s\nbuilt=%s\n' "$RELEASE_ID" "$sha" "$(date -u '+%FT%TZ')" >"$rel/RELEASE"
  printf '%s\n' "$hash" >"$rel/.source-hash"
  chown -R root:root "$rel"
  chmod -R go-w "$rel"

  smoke_test_release "$rel"
  switch_release "$rel"
}

prune_releases() {
  local cur prev d i=0
  cur="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
  prev="$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || true)"
  while IFS= read -r d; do
    i=$((i + 1))
    if (( i <= KEEP_RELEASES )); then continue; fi
    if [[ "$d" == "$cur" || "$d" == "$prev" ]]; then continue; fi
    log "Removing old release $(basename "$d")"
    rm -rf -- "$d"
  done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -print | LC_ALL=C sort -r)
}

render_unit() {
  cat <<EOF
# Managed by install-i3-qc.sh - re-running the installer rewrites this file.
[Unit]
Description=I3 Design QC App (Node.js backend serving the built frontend)
After=network-online.target
Wants=network-online.target
RequiresMountsFor=$PROJECTS_ROOT
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$CURRENT_LINK/backend
EnvironmentFile=$ENV_FILE
ExecStart=$NODE_BIN $BACKEND_ENTRY
Restart=on-failure
RestartSec=3
TimeoutStopSec=20
# Group-writable files so teammates can open qc-overrides/ and backups on a shared folder.
UMask=0002

# Sandboxing. MemoryDenyWriteExecute is deliberately NOT set: V8 and WebAssembly (gdal3.js) need it.
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectClock=true
ProtectHostname=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictNamespaces=true
LockPersonality=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
CapabilityBoundingSet=
AmbientCapabilities=
ReadWritePaths=$STATE_DIR $PROJECTS_ROOT

[Install]
WantedBy=multi-user.target
EOF
}

# Hosts with IPv6 disabled make nginx -t fail on `listen [::]:...`, so only emit those when IPv6 works.
ipv6_available() {
  [[ -r /proc/net/if_inet6 ]] || return 1
  [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "0" ]]
}

# Server-level directives shared by the HTTP-only and HTTPS variants.
render_server_body() {
  local c
  cat <<EOF
    server_name $SERVER_NAME;
    server_tokens off;
    client_max_body_size 5m;

    gzip on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types application/json application/geo+json text/css application/javascript text/javascript image/svg+xml;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "DENY" always;
    add_header Referrer-Policy "no-referrer" always;
EOF
  if [[ "$TLS_MODE" == "provided" ]]; then
    printf '    add_header Strict-Transport-Security "max-age=31536000" always;\n'
  fi
  if [[ ${#ALLOW_CIDRS[@]} -gt 0 ]]; then
    printf '\n    # Network allow-list (loopback is always allowed for local health checks)\n'
    printf '    allow 127.0.0.1;\n    allow ::1;\n'
    for c in "${ALLOW_CIDRS[@]}"; do printf '    allow %s;\n' "$c"; done
    printf '    deny all;\n'
  fi
  if [[ "$AUTH_MODE" == "basic" ]]; then
    printf '\n    auth_basic "I3 Design QC";\n    auth_basic_user_file %s;\n' "$HTPASSWD_FILE"
  fi
  cat <<EOF

    # Proxy settings inherited by both locations below.
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    # Always overwritten here so clients cannot spoof it; the app audit log trusts it.
    proxy_set_header X-Remote-User \$remote_user;
    proxy_read_timeout 300s;
    proxy_send_timeout 300s;

    location = /api/healthz {
        auth_basic off;
        access_log off;
        proxy_pass http://i3qc_backend;
    }

    location / {
        proxy_pass http://i3qc_backend;
    }
EOF
}

render_nginx() {
  cat <<EOF
# Managed by install-i3-qc.sh - re-running the installer rewrites this file.
# Put local tweaks in a separate file under /etc/nginx/conf.d/.
upstream i3qc_backend {
    server 127.0.0.1:$PORT;
    keepalive 16;
}

EOF
  if [[ "$TLS_MODE" == "none" ]]; then
    printf 'server {\n    listen 80;\n'
    if ipv6_available; then printf '    listen [::]:80;\n'; fi
    render_server_body
    printf '}\n'
    return 0
  fi
  printf 'server {\n    listen 80;\n'
  if ipv6_available; then printf '    listen [::]:80;\n'; fi
  cat <<EOF
    server_name $SERVER_NAME;
    return 301 https://$SERVER_NAME\$request_uri;
}

server {
    listen 443 ssl http2;
EOF
  if ipv6_available; then printf '    listen [::]:443 ssl http2;\n'; fi
  cat <<EOF
    ssl_certificate     $CERT_PATH;
    ssl_certificate_key $KEY_PATH;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:i3qc_ssl:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

EOF
  render_server_body
  printf '}\n'
}

ensure_tls() {
  local san
  case "$TLS_MODE" in
    none) return 0 ;;
    provided) CERT_PATH="$TLS_CERT"; KEY_PATH="$TLS_KEY"; return 0 ;;
    *) ;;
  esac
  CERT_PATH="$TLS_DIR/i3-qc.crt"
  KEY_PATH="$TLS_DIR/i3-qc.key"
  install -d -m 0755 "$TLS_DIR"
  if [[ -s "$CERT_PATH" && -s "$KEY_PATH" ]] \
     && openssl x509 -noout -ext subjectAltName -in "$CERT_PATH" 2>/dev/null | grep -qF "$SERVER_NAME"; then
    if ! openssl x509 -noout -checkend $((30 * 86400)) -in "$CERT_PATH" >/dev/null; then
      warn "Self-signed certificate expires within 30 days; delete $TLS_DIR/i3-qc.* and re-run to regenerate"
    fi
    return 0
  fi
  if [[ "$SERVER_NAME" =~ ^[0-9.]+$ ]]; then san="IP:$SERVER_NAME"; else san="DNS:$SERVER_NAME"; fi
  log "Generating self-signed certificate for $SERVER_NAME (browsers will warn until it is trusted)"
  openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 825 \
    -keyout "$KEY_PATH" -out "$CERT_PATH" -subj "/CN=$SERVER_NAME" -addext "subjectAltName=$san" 2>/dev/null
  chmod 0600 "$KEY_PATH"
  chmod 0644 "$CERT_PATH"
}

setup_auth() {
  [[ "$AUTH_MODE" == "basic" ]] || return 0
  if [[ -s "$HTPASSWD_FILE" ]] && (( ! RESET_AUTH )); then
    log "Keeping existing basic-auth file (use --reset-auth to regenerate; add users with: htpasswd -B $HTPASSWD_FILE NAME)"
    return 0
  fi
  local pw="${I3QC_AUTH_PASSWORD:-}"
  if [[ -z "$pw" ]]; then
    pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)"
    GENERATED_PASSWORD="$pw"
  fi
  htpasswd -i -B -c "$HTPASSWD_FILE" "$AUTH_USER" <<<"$pw" 2>/dev/null
  chown root:www-data "$HTPASSWD_FILE"
  chmod 0640 "$HTPASSWD_FILE"
  log "Basic-auth user '$AUTH_USER' configured"
}

configure_nginx() {
  local changed=0 backup=""
  ensure_tls
  setup_auth
  if [[ -f "$NGINX_SITE" ]]; then backup="$(mktemp)"; cp -p "$NGINX_SITE" "$backup"; fi
  write_managed_file "$NGINX_SITE" 0644 < <(render_nginx)
  if (( FILE_CHANGED )); then changed=1; fi
  if [[ ! -L "$NGINX_LINK" ]]; then ln -sfn "$NGINX_SITE" "$NGINX_LINK"; changed=1; fi
  if (( changed )); then
    if ! nginx -t; then
      if [[ -n "$backup" ]]; then cp -p "$backup" "$NGINX_SITE"; else rm -f "$NGINX_LINK" "$NGINX_SITE"; fi
      rm -f "$backup"
      die "nginx configuration test failed; previous configuration restored"
    fi
  fi
  rm -f "$backup"
  systemctl enable nginx >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet nginx; then
    log "Starting nginx"
    systemctl start nginx
  elif (( changed )); then
    systemctl reload nginx
    log "nginx site updated and reloaded"
  else
    log "nginx site unchanged"
  fi
}

configure_firewall() {
  local port ports
  if (( CONFIGURE_FIREWALL )); then
    apt-get install -y -qq ufw
    ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')"
    for port in ${ports:-22}; do ufw allow "${port}/tcp" >/dev/null; done
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw --force enable >/dev/null
    log "Firewall: ufw enabled with SSH (${ports:-22}), 80 and 443 allowed"
  elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
    ufw allow 80/tcp >/dev/null
    ufw allow 443/tcp >/dev/null
    log "Firewall: ufw already active; ensured 80 and 443 are allowed"
  else
    log "Firewall: not changed (use --configure-firewall to enable ufw with SSH, 80 and 443)"
  fi
}

probe_nginx() {
  local scheme="https" code
  if [[ "$TLS_MODE" == "none" ]]; then scheme="http"; fi
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $SERVER_NAME" "$scheme://127.0.0.1/api/healthz" || true)"
  if [[ "$code" == "200" ]]; then
    log "nginx front door OK (GET /api/healthz -> 200)"
  else
    warn "nginx front door check returned HTTP $code for /api/healthz"
  fi
  if [[ "$AUTH_MODE" == "basic" ]]; then
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: $SERVER_NAME" "$scheme://127.0.0.1/" || true)"
    if [[ "$code" == "401" ]]; then log "Auth gate OK (401 without credentials)"; else warn "Expected 401 without credentials, got $code"; fi
  fi
}

activate_service() {
  write_managed_file "$UNIT_FILE" 0644 < <(render_unit)
  if (( FILE_CHANGED )); then CHANGED=1; systemctl daemon-reload; fi
  systemctl enable "$APP_NAME" >/dev/null 2>&1
  if ! systemctl is-active --quiet "$APP_NAME"; then
    log "Starting $APP_NAME"
    systemctl start "$APP_NAME"
  elif (( CHANGED )); then
    log "Restarting $APP_NAME (release, unit or settings changed)"
    systemctl restart "$APP_NAME"
  else
    log "$APP_NAME already running with current settings; no restart needed"
  fi
  if probe_app "http://127.0.0.1:$PORT" 30; then
    log "Backend healthy via ${PROBE_MODE} on 127.0.0.1:$PORT"
  else
    journalctl -u "$APP_NAME" -n 40 --no-pager >&2 || true
    if [[ -L "$PREVIOUS_LINK" && -n "$RELEASE_ID" ]]; then
      warn "Service unhealthy after switching to $RELEASE_ID; rolling back automatically"
      do_rollback
      rm -rf -- "${RELEASES_DIR:?}/$RELEASE_ID"
      repoint_previous
      die "Rolled back to the previous release; release $RELEASE_ID was discarded because it did not become healthy"
    fi
    die "Service did not become healthy; see: journalctl -u $APP_NAME -n 100"
  fi
  probe_nginx
}

do_rollback() {
  local prev cur
  [[ -L "$PREVIOUS_LINK" ]] || die "No previous release recorded; nothing to roll back to"
  prev="$(readlink -f "$PREVIOUS_LINK")"
  cur="$(readlink -f "$CURRENT_LINK")"
  [[ -d "$prev" ]] || die "Previous release directory is missing: $prev"
  point_link "$PREVIOUS_LINK" "$cur"
  point_link "$CURRENT_LINK" "$prev"
  log "Rolled back: current is now $(basename "$prev") (previous is $(basename "$cur"))"
  systemctl restart "$APP_NAME"
  if probe_app "http://127.0.0.1:$(env_get PORT)" 30; then log "Service healthy after rollback"; else warn "Service not healthy after rollback; check journalctl -u $APP_NAME"; fi
}

do_status() {
  local port
  port="$(env_get PORT)"; port="${port:-4000}"
  echo "Release   : $(readlink -f "$CURRENT_LINK" 2>/dev/null || echo 'none installed')"
  if [[ -f "$CURRENT_LINK/RELEASE" ]]; then sed 's/^/            /' "$CURRENT_LINK/RELEASE"; fi
  echo "Previous  : $(readlink -f "$PREVIOUS_LINK" 2>/dev/null || echo 'none')"
  echo "Service   : active=$(systemctl is-active "$APP_NAME" 2>/dev/null || true) enabled=$(systemctl is-enabled "$APP_NAME" 2>/dev/null || true)"
  echo "nginx     : active=$(systemctl is-active nginx 2>/dev/null || true)"
  if probe_app "http://127.0.0.1:$port" 3; then echo "Health    : OK via $PROBE_MODE on 127.0.0.1:$port"; else echo "Health    : FAILED on 127.0.0.1:$port"; fi
  if [[ -s "$TLS_DIR/i3-qc.crt" ]]; then echo "Cert      : $(openssl x509 -noout -enddate -in "$TLS_DIR/i3-qc.crt")"; fi
  echo "Settings  : $ENV_FILE"
  grep -v '^#' "$ENV_FILE" 2>/dev/null | sed 's/^/            /' || true
  echo "Releases  : $(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l) kept in $RELEASES_DIR"
  echo "Recent log:"
  journalctl -u "$APP_NAME" -n 10 --no-pager 2>/dev/null | sed 's/^/            /' || true
}

do_uninstall() {
  (( ASSUME_YES )) || die "uninstall removes the service, nginx site and releases. Re-run with --yes to confirm (add --purge to also delete config and state; project data is never touched)."
  log "Stopping and removing the service"
  systemctl disable --now "$APP_NAME" >/dev/null 2>&1 || true
  rm -f "$UNIT_FILE"
  systemctl daemon-reload
  rm -f "$NGINX_LINK" "$NGINX_SITE"
  if nginx -t >/dev/null 2>&1; then systemctl reload nginx 2>/dev/null || true; fi
  rm -rf -- "$INSTALL_ROOT"
  if (( PURGE )); then
    log "Purging config, state, certificates and the service account"
    rm -rf -- "$CONF_DIR" "$STATE_DIR" "$TLS_DIR"
    rm -f "$HTPASSWD_FILE"
    userdel "$APP_USER" 2>/dev/null || true
    if getent group "$APP_GROUP" >/dev/null; then groupdel "$APP_GROUP" 2>/dev/null || true; fi
  else
    log "Kept $CONF_DIR, $STATE_DIR and certificates (use --purge to delete them)"
  fi
  log "Uninstalled. Project data was not touched."
}

print_summary() {
  local scheme="https"
  if [[ "$TLS_MODE" == "none" ]]; then scheme="http"; fi
  log "Done."
  echo
  echo "  URL        : $scheme://$SERVER_NAME/"
  echo "  Release    : $(basename "$(readlink -f "$CURRENT_LINK")")"
  echo "  Projects   : $PROJECTS_ROOT  (copy or mount ArcGIS project folders here)"
  echo "  Settings   : $ENV_FILE"
  echo "  Service    : systemctl status $APP_NAME   |   journalctl -u $APP_NAME -f"
  echo "  Operations : sudo $SCRIPT_PATH status | rollback"
  if [[ "$TLS_MODE" == "selfsigned" ]]; then
    echo "  TLS        : self-signed ($TLS_DIR/i3-qc.crt). Import it as a trusted root on user PCs, or use --tls provided."
  fi
  if [[ "$TLS_MODE" == "none" && "$AUTH_MODE" == "basic" ]]; then
    warn "Basic-auth credentials travel in clear text over plain HTTP; use TLS."
  fi
  if [[ -n "$GENERATED_PASSWORD" ]]; then
    {
      echo
      echo "  Login      : user '$AUTH_USER'  password '$GENERATED_PASSWORD'"
      echo "  (shown once and NOT written to the log; store it now)"
    } >&3
  fi
}

do_install() {
  check_os
  validate_options
  resolve_source
  install_packages
  install_node
  ensure_user
  resolve_settings
  ensure_dirs
  write_env_file
  build_release
  configure_nginx
  configure_firewall
  activate_service
  prune_releases
  print_summary
}

main() {
  parse_args "$@"
  require_root "$@"
  exec 3>&1
  install -m 0640 /dev/null "$LOG_FILE" 2>/dev/null || true
  exec > >(tee -a "$LOG_FILE") 2>&1
  trap cleanup EXIT
  trap 'warn "failed near line $LINENO (exit $?); see $LOG_FILE"' ERR
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another install-i3-qc.sh run is in progress"
  case "$COMMAND" in
    install)   do_install ;;
    rollback)  do_rollback ;;
    status)    do_status ;;
    uninstall) do_uninstall ;;
    *)         die "Unknown command: $COMMAND" ;;
  esac
}

# Run only when executed, not when sourced (lets tests call the functions).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
