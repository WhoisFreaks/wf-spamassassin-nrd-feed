#!/usr/bin/env bash
# install.sh — WhoisFreaks NRD Feed for SpamAssassin + Postfix
#
# Distro-aware installer. Detects the Linux distribution and uses the
# correct package manager, service name, and spamd user automatically.
#
# Tested on:
#   Debian/Ubuntu   — apt-get, service: spamassassin, user: debian-spamd
#   RHEL/CentOS/Rocky/AlmaLinux — dnf/yum, service: spamassassin, user: spamd
#   Fedora          — dnf, service: spamassassin, user: spamd
#   openSUSE/SLES   — zypper, service: spamd, user: spamd
#   Arch Linux      — pacman, service: spamassassin, user: spamd
#
# Usage:
#   sudo ./install.sh
#
# Optional env vars:
#   WINDOW_DAYS=10       Days of NRD history to keep (default: 10)
#   REJECT_SCORE=15      Score above which spamass-milter rejects at SMTP time

set -euo pipefail

# ── Defaults ───────────────────────────────────────────────────────────────────
WINDOW_DAYS="${WINDOW_DAYS:-10}"
REJECT_SCORE="${REJECT_SCORE:-15}"
API_KEY_FILE="/etc/whoisfreaks/apikey"
LIST_DIR="/var/lib/spamassassin/nrd"
LIST_FILE="$LIST_DIR/nrd_domains.list"
CACHE_DIR="/var/cache/wf-nrd"
FETCH_SCRIPT="/usr/local/bin/wf-nrd-sa-fetch.sh"
SA_DIR="/etc/spamassassin"
CRON_FILE="/etc/cron.d/wf-nrd-spamassassin"
LOG_FILE="/var/log/wf-nrd-spamassassin.log"

# ── Colours ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${YELLOW}[·]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Root check ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || err "Please run as root: sudo ./install.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Distro detection ───────────────────────────────────────────────────────────
detect_distro() {
  PKG_MANAGER=""
  DISTRO_FAMILY=""
  SA_SERVICE="spamassassin"
  SPAMD_USER="spamd"

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    ID_LOWER="${ID,,}"
    ID_LIKE_LOWER="${ID_LIKE,,}"
  else
    ID_LOWER=""
    ID_LIKE_LOWER=""
  fi

  # Debian / Ubuntu family
  if command -v apt-get &>/dev/null || \
     [[ "$ID_LOWER" =~ ^(debian|ubuntu|linuxmint|pop|elementary|kali|raspbian)$ ]] || \
     [[ "$ID_LIKE_LOWER" =~ debian ]]; then
    PKG_MANAGER="apt"
    DISTRO_FAMILY="debian"
    SA_SERVICE="spamassassin"
    # Ubuntu/Debian run spamd as debian-spamd
    SPAMD_USER="debian-spamd"

  # RHEL / CentOS / Rocky / Alma / Fedora family
  elif command -v dnf &>/dev/null || command -v yum &>/dev/null || \
       [[ "$ID_LOWER" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|scientific)$ ]] || \
       [[ "$ID_LIKE_LOWER" =~ (rhel|fedora) ]]; then
    PKG_MANAGER="dnf"
    command -v dnf &>/dev/null || PKG_MANAGER="yum"
    DISTRO_FAMILY="rhel"
    SA_SERVICE="spamassassin"
    SPAMD_USER="spamd"

  # openSUSE / SLES family
  elif command -v zypper &>/dev/null || \
       [[ "$ID_LOWER" =~ ^(opensuse|sles|suse)$ ]] || \
       [[ "$ID_LIKE_LOWER" =~ suse ]]; then
    PKG_MANAGER="zypper"
    DISTRO_FAMILY="suse"
    SA_SERVICE="spamd"      # openSUSE uses 'spamd' as the service name
    SPAMD_USER="spamd"

  # Arch Linux family
  elif command -v pacman &>/dev/null || \
       [[ "$ID_LOWER" =~ ^(arch|manjaro|endeavouros|garuda)$ ]]; then
    PKG_MANAGER="pacman"
    DISTRO_FAMILY="arch"
    SA_SERVICE="spamassassin"
    SPAMD_USER="spamd"

  else
    err "Unsupported distro. Supported: Debian/Ubuntu, RHEL/CentOS/Rocky/Alma/Fedora, openSUSE/SLES, Arch Linux."
  fi
}

detect_distro
ok "Detected distro family: $DISTRO_FAMILY (pkg: $PKG_MANAGER, spamd user: $SPAMD_USER, service: $SA_SERVICE)"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   WhoisFreaks NRD Feed — SpamAssassin + Postfix Installer   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Install packages ───────────────────────────────────────────────────
info "Installing SpamAssassin, spamass-milter, Postfix, and curl..."

case "$PKG_MANAGER" in
  apt)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq spamassassin spamass-milter postfix curl
    ;;
  dnf)
    dnf install -y spamassassin postfix curl
    # spamass-milter may be in EPEL on RHEL-family
    if dnf list available spamass-milter &>/dev/null 2>&1; then
      dnf install -y spamass-milter
    else
      warn "spamass-milter not found in repos — skipping milter install."
      warn "Install EPEL first: dnf install epel-release, then re-run."
    fi
    ;;
  yum)
    yum install -y spamassassin postfix curl
    if yum list available spamass-milter &>/dev/null 2>&1; then
      yum install -y spamass-milter
    else
      warn "spamass-milter not found — skipping. Install EPEL to get it."
    fi
    ;;
  zypper)
    zypper install -y spamassassin postfix curl
    # openSUSE calls it spamassassin-milter or similar
    if zypper search spamass-milter | grep -q spamass-milter 2>/dev/null; then
      zypper install -y spamass-milter
    else
      warn "spamass-milter not available via zypper — skipping."
    fi
    ;;
  pacman)
    pacman -Sy --noconfirm spamassassin postfix curl
    # spamass-milter is in AUR on Arch; skip automatic install
    warn "spamass-milter is in the AUR on Arch — install manually if needed."
    warn "  yay -S spamass-milter  (or paru / makepkg)"
    ;;
esac

ok "Packages installed"

# ── Step 2: API Key ────────────────────────────────────────────────────────────
mkdir -p /etc/whoisfreaks

if [[ -f "$API_KEY_FILE" && -s "$API_KEY_FILE" ]]; then
  ok "API key already present at $API_KEY_FILE — skipping"
else
  echo ""
  read -rp "  Enter your WhoisFreaks API key: " WF_API_KEY
  echo ""
  [[ -n "$WF_API_KEY" ]] || err "API key cannot be empty."
  echo "$WF_API_KEY" > "$API_KEY_FILE"
  chmod 600 "$API_KEY_FILE"
  ok "API key stored at $API_KEY_FILE (chmod 600)"
fi

# ── Step 3: Create directories ─────────────────────────────────────────────────
info "Creating directories..."
mkdir -p "$LIST_DIR" "$CACHE_DIR"

# Set ownership to the spamd user so the daemon can read the list
if id "$SPAMD_USER" &>/dev/null; then
  chown "$SPAMD_USER:$SPAMD_USER" "$LIST_DIR" 2>/dev/null || true
else
  warn "spamd user '$SPAMD_USER' not found yet — ownership will be set after package install completes on first run."
fi

touch "$LIST_FILE" 2>/dev/null || true
ok "Directories ready ($LIST_DIR)"

# ── Step 4: Install fetch script ───────────────────────────────────────────────
info "Installing fetch script..."
install -m 755 "$SCRIPT_DIR/fetch/wf-nrd-fetch.sh" "$FETCH_SCRIPT"
ok "Fetch script installed at $FETCH_SCRIPT"

# ── Step 5: Install SpamAssassin plugin and rules ──────────────────────────────
info "Installing SpamAssassin plugin files..."

for f in wf-nrd.pre wf-nrd.cf WhoisFreaksNRD.pm; do
  if [[ -f "$SA_DIR/$f" ]]; then
    cp "$SA_DIR/$f" "$SA_DIR/${f}.bak.$(date +%Y%m%d%H%M%S)"
    info "Backed up existing $f"
  fi
done

install -m 644 "$SCRIPT_DIR/spamassassin/WhoisFreaksNRD.pm" "$SA_DIR/WhoisFreaksNRD.pm"
install -m 644 "$SCRIPT_DIR/spamassassin/wf-nrd.pre"        "$SA_DIR/wf-nrd.pre"
install -m 644 "$SCRIPT_DIR/spamassassin/wf-nrd.cf"         "$SA_DIR/wf-nrd.cf"

ok "Plugin files installed at $SA_DIR/"

# ── Step 6: Configure SpamAssassin daemon ──────────────────────────────────────
info "Configuring SpamAssassin daemon..."

# Debian/Ubuntu: /etc/default/spamassassin has ENABLED=0 by default
SA_DEFAULT="/etc/default/spamassassin"
if [[ -f "$SA_DEFAULT" ]]; then
  sed -i 's/^ENABLED=0/ENABLED=1/' "$SA_DEFAULT" 2>/dev/null || true
fi

# RHEL family: spamd options live in /etc/mail/spamassassin/local.cf
# or /etc/sysconfig/spamassassin — no ENABLED flag needed; just enable service
if [[ "$DISTRO_FAMILY" == "rhel" ]]; then
  SYSCONFIG_SA="/etc/sysconfig/spamassassin"
  if [[ -f "$SYSCONFIG_SA" ]] && ! grep -q 'SPAMDOPTIONS' "$SYSCONFIG_SA"; then
    echo 'SPAMDOPTIONS="-d -c -m5 -H"' >> "$SYSCONFIG_SA"
  fi
fi

# Ensure local.cf has sensible defaults if empty/new
LOCAL_CF="$SA_DIR/local.cf"
if [[ ! -f "$LOCAL_CF" ]] || ! grep -q 'required_score' "$LOCAL_CF" 2>/dev/null; then
  cat >> "$LOCAL_CF" <<'EOF'

# WhoisFreaks NRD Feed — baseline SpamAssassin settings
rewrite_header Subject [SPAM]
report_safe 0
required_score 5.0
use_bayes 1
bayes_auto_learn 1
EOF
  ok "Baseline settings added to local.cf"
fi

ok "SpamAssassin daemon configured"

# ── Step 7: Configure Postfix content filter ───────────────────────────────────
info "Configuring Postfix content filter..."

MASTER_CF="/etc/postfix/master.cf"

if grep -q 'content_filter=spamassassin' "$MASTER_CF" 2>/dev/null; then
  ok "Postfix content_filter already configured — skipping"
else
  sed -i '/^smtp[[:space:]]*inet/a\    -o content_filter=spamassassin' "$MASTER_CF"
  ok "Added content_filter=spamassassin to Postfix smtp service"
fi

if grep -q '^spamassassin ' "$MASTER_CF" 2>/dev/null; then
  ok "SpamAssassin transport already in master.cf — skipping"
else
  cat >> "$MASTER_CF" <<'EOF'

# WhoisFreaks NRD Feed — SpamAssassin content filter transport
spamassassin unix  -       n       n       -       -       pipe
  user=spamd argv=/usr/bin/spamc -f -e /usr/sbin/sendmail -oi -f ${sender} ${recipient}
EOF
  ok "SpamAssassin transport added to master.cf"
fi

# ── Step 8: Configure spamass-milter ──────────────────────────────────────────
info "Configuring spamass-milter (reject score: $REJECT_SCORE)..."

MILTER_DEFAULT="/etc/default/spamass-milter"
MILTER_SYSCONFIG="/etc/sysconfig/spamass-milter"

if [[ -f "$MILTER_DEFAULT" ]]; then
  sed -i "s|^OPTIONS=.*|OPTIONS=\"-u spamass-milter -i 127.0.0.1 -r ${REJECT_SCORE}\"|" \
    "$MILTER_DEFAULT" 2>/dev/null || true
elif [[ -f "$MILTER_SYSCONFIG" ]]; then
  sed -i "s|^MILTER_FLAGS=.*|MILTER_FLAGS=\"-u spamass-milter -i 127.0.0.1 -r ${REJECT_SCORE}\"|" \
    "$MILTER_SYSCONFIG" 2>/dev/null || true
fi
ok "spamass-milter configured"

# ── Step 9: Seed the NRD list ──────────────────────────────────────────────────
info "Seeding NRD domain list (window: ${WINDOW_DAYS} days)..."
touch "$LOG_FILE"
WINDOW_DAYS="$WINDOW_DAYS" API_KEY_FILE="$API_KEY_FILE" "$FETCH_SCRIPT" \
  >> "$LOG_FILE" 2>&1 || {
    echo ""
    warn "Initial seed encountered errors. Check $LOG_FILE"
    warn "The cron job will retry at 05:00 UTC."
    echo ""
  }
ok "NRD list seeded"

# ── Step 10: Enable and start services ────────────────────────────────────────
info "Enabling and starting services..."

# SpamAssassin
systemctl enable "$SA_SERVICE" --now 2>/dev/null \
  || systemctl restart "$SA_SERVICE" 2>/dev/null \
  || warn "Could not start $SA_SERVICE — start it manually: systemctl start $SA_SERVICE"

# spamass-milter (best-effort; not available on all distros)
for milter_svc in spamass-milter spamass_milter; do
  if systemctl list-unit-files "$milter_svc.service" &>/dev/null 2>&1; then
    systemctl enable "$milter_svc" --now 2>/dev/null \
      || systemctl restart "$milter_svc" 2>/dev/null || true
    break
  fi
done

# Postfix
systemctl reload postfix 2>/dev/null || systemctl restart postfix

ok "Services running"

# ── Step 11: Install cron job ──────────────────────────────────────────────────
info "Installing cron job..."
sed "s/WINDOW_DAYS=10/WINDOW_DAYS=${WINDOW_DAYS}/" \
  "$SCRIPT_DIR/cron/wf-nrd-spamassassin" > "$CRON_FILE"
chmod 644 "$CRON_FILE"
ok "Cron job installed at $CRON_FILE"

# ── Validate ───────────────────────────────────────────────────────────────────
echo ""
echo "── Validation ────────────────────────────────────────────────────────────"
info "Linting SpamAssassin config..."
if spamassassin --lint 2>&1 | grep -i error; then
  warn "sa --lint reported errors — check your config"
else
  ok "sa --lint: no errors"
fi

DOMAIN_COUNT=$(wc -l < "$LIST_FILE" 2>/dev/null || echo 0)
ok "NRD list: $DOMAIN_COUNT domains"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  Installation complete!                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Distro family:  $DISTRO_FAMILY"
echo "  SA service:     $SA_SERVICE"
echo "  spamd user:     $SPAMD_USER"
echo ""
echo "  NRD list:       $LIST_FILE"
echo "  Fetch script:   $FETCH_SCRIPT"
echo "  Cron job:       $CRON_FILE"
echo "  SA plugin:      $SA_DIR/WhoisFreaksNRD.pm"
echo "  SA rules:       $SA_DIR/wf-nrd.cf"
echo "  Fetch log:      $LOG_FILE"
echo ""
echo "  Rule added:  WF_NRD_SENDER (+3.5 score on NRD sender domain)"
echo ""
echo "  To test:  echo 'test' | spamassassin -D 2>&1 | grep -i nrd"
echo "  To tune:  edit $SA_DIR/wf-nrd.cf  -> change score WF_NRD_SENDER"
echo ""