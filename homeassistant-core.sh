#!/usr/bin/env bash
set -Eeuo pipefail

#############################################
# Home Assistant Core on Debian 13 (LXC)
# - Proxmox-host mode: create CT + install
# - In-container mode: install + systemd unit
#############################################

log() { printf '%s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

is_proxmox_host() {
  [[ -d /etc/pve ]] && command -v pct >/dev/null 2>&1
}

# -------- Config (override via env vars) --------
CTID="${CTID:-}"
HOSTNAME_CT="${HOSTNAME_CT:-homeassistant-core}"
CORES="${CORES:-4}"
RAM_MB="${RAM_MB:-4096}"
DISK_GB="${DISK_GB:-32}"
BRIDGE="${BRIDGE:-vmbr0}"
IPCFG="${IPCFG:-dhcp}"   # e.g. "dhcp" or "192.168.1.50/24,gw=192.168.1.1"
UNPRIVILEGED="${UNPRIVILEGED:-0}"  # 0=privileged, 1=unprivileged
ONBOOT="${ONBOOT:-1}"
TIMEZONE="${TIMEZONE:-host}"

# Install paths
HA_USER="${HA_USER:-homeassistant}"
HA_GROUP="${HA_GROUP:-homeassistant}"
HA_BASE="${HA_BASE:-/srv/homeassistant}"
HA_VENV="${HA_VENV:-/srv/homeassistant/.venv}"
HA_CONFIG="${HA_CONFIG:-/var/lib/homeassistant}"

# -------- In-container installer --------
install_inside_container() {
  log "==> Installing Home Assistant Core (venv) + systemd service on Debian"

  need_cmd apt-get
  need_cmd systemctl
  need_cmd python3

  local py_mm
  py_mm="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
  if [[ "$py_mm" != "3.13" ]]; then
    die "python3 is $py_mm, expected 3.13 (Debian 13)."
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y

  # Core build + HA common deps (close to the historical helper script, updated for Debian 13)
  apt-get install -y --no-install-recommends \
    ca-certificates curl git sudo mc \
    python3 python3-venv python3-pip python3-dev \
    build-essential autoconf pkg-config \
    libffi-dev libssl-dev libjpeg-dev zlib1g-dev \
    libopenjp2-7 libturbojpeg0-dev \
    ffmpeg \
    liblapack3 liblapack-dev libatlas-base-dev \
    libpcap-dev \
    libavdevice-dev libavformat-dev libavcodec-dev libavutil-dev libavfilter-dev \
    libmariadb-dev-compat libmariadb-dev \
    dbus-broker \
    bluez

  # Create service user (idempotent)
  if ! id -u "$HA_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$HA_CONFIG" --shell /usr/sbin/nologin "$HA_USER"
  fi
  mkdir -p "$HA_BASE" "$HA_CONFIG"
  chown -R "$HA_USER:$HA_GROUP" "$HA_BASE" "$HA_CONFIG" || true

  # Helpful compatibility symlink for people expecting /root/.homeassistant
  mkdir -p /root
  ln -sfn "$HA_CONFIG" /root/.homeassistant

  # Create venv (idempotent)
  if [[ ! -x "${HA_VENV}/bin/python" ]]; then
    log "==> Creating venv at ${HA_VENV}"
    python3 -m venv "$HA_VENV"
    chown -R "$HA_USER:$HA_GROUP" "$HA_VENV" || true
  fi

  # Install HA
  log "==> Installing Home Assistant Core into venv"
  sudo -u "$HA_USER" -H "${HA_VENV}/bin/python" -m pip install --upgrade pip setuptools wheel
  sudo -u "$HA_USER" -H "${HA_VENV}/bin/pip" install --prefer-binary \
    homeassistant \
    mysqlclient psycopg2-binary isal webrtcvad

  # Systemd unit
  log "==> Creating /etc/systemd/system/homeassistant.service"
  cat >/etc/systemd/system/homeassistant.service <<EOF
[Unit]
Description=Home Assistant Core
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${HA_USER}
Group=${HA_GROUP}
WorkingDirectory=${HA_CONFIG}
Environment="PATH=${HA_VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ExecStart=${HA_VENV}/bin/python -m homeassistant --config ${HA_CONFIG}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now homeassistant

  log "==> Installed. Check status with: systemctl status homeassistant -l --no-pager"
  log "==> Logs: journalctl -u homeassistant -f"
}

# -------- Proxmox host mode: create CT + run installer --------
pick_storage() {
  local content="$1"
  # First available storage that supports given content type
  pvesm status -content "$content" 2>/dev/null | awk 'NR>1 {print $1; exit}'
}

pick_debian13_template() {
  pveam update >/dev/null 2>&1 || true
  pveam available -section system 2>/dev/null | awk '/debian-13-standard_.*amd64/ {print $2}' | tail -n 1
}

next_ctid() {
  if command -v pvesh >/dev/null 2>&1; then
    pvesh get /cluster/nextid 2>/dev/null || true
  fi
  return 0
}

create_and_install_on_proxmox() {
  need_cmd pct
  need_cmd pveam
  need_cmd pvesm
  need_cmd awk

  local tmpl_storage root_storage template
  tmpl_storage="$(pick_storage vztmpl)"
  root_storage="$(pick_storage rootdir)"
  [[ -n "$tmpl_storage" ]] || die "No storage found for templates (vztmpl)."
  [[ -n "$root_storage" ]] || die "No storage found for containers (rootdir)."

  template="$(pick_debian13_template)"
  [[ -n "$template" ]] || die "Could not find a Debian 13 template via pveam."

  if [[ -z "${CTID}" ]]; then
    CTID="$(next_ctid)"
  fi
  [[ -n "${CTID}" ]] || die "CTID not set and could not auto-detect. Set CTID=#### and retry."

  log "==> Using template: ${template}"
  log "==> Template storage: ${tmpl_storage}, Rootfs storage: ${root_storage}"
  log "==> Creating CTID: ${CTID} (hostname: ${HOSTNAME_CT})"

  # Ensure template downloaded
  if ! pveam list "$tmpl_storage" | awk '{print $1}' | grep -qx "$template"; then
    log "==> Downloading template to ${tmpl_storage}..."
    pveam download "$tmpl_storage" "$template"
  fi

  # Root password: random unless provided
  local CT_PASSWORD="${CT_PASSWORD:-}"
  if [[ -z "$CT_PASSWORD" ]]; then
    need_cmd openssl
    CT_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  fi
  local pwfile
  pwfile="$(mktemp)"
  printf '%s\n' "$CT_PASSWORD" >"$pwfile"

  # Network string
  local net0="name=eth0,bridge=${BRIDGE},ip=${IPCFG}"
  if [[ "$IPCFG" != "dhcp" && "$IPCFG" == *",gw="* ]]; then
    # Convert "ip/cidr,gw=x" to pct syntax: ip=...,gw=...
    local ip_part gw_part
    ip_part="${IPCFG%%,gw=*}"
    gw_part="${IPCFG##*,gw=}"
    net0="name=eth0,bridge=${BRIDGE},ip=${ip_part},gw=${gw_part}"
  fi

  # Create CT
  pct create "$CTID" "${tmpl_storage}:vztmpl/${template}" \
    --ostype debian \
    --arch amd64 \
    --hostname "$HOSTNAME_CT" \
    --cores "$CORES" \
    --memory "$RAM_MB" \
    --swap 0 \
    --rootfs "${root_storage}:${DISK_GB}" \
    --net0 "$net0" \
    --features nesting=1,keyctl=1 \
    --unprivileged "$UNPRIVILEGED" \
    --onboot "$ONBOOT" \
    --timezone "$TIMEZONE" \
    --password-file "$pwfile"

  rm -f "$pwfile"

  log "==> Starting CT ${CTID}"
  pct start "$CTID"

  log "==> Running in-container installer"
  pct exec "$CTID" -- bash -lc "$(declare -f log die need_cmd install_inside_container); install_inside_container"

  local ip
  ip="$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'" 2>/dev/null || true)"
  log "==> Done."
  log "==> CTID: ${CTID}"
  log "==> Root password: ${CT_PASSWORD}"
  if [[ -n "$ip" ]]; then
    log "==> Home Assistant URL: http://${ip}:8123"
  else
    log "==> Home Assistant URL: http://<ct-ip>:8123"
  fi
}

main() {
  case "${1:-}" in
    --install-only)
      install_inside_container
      ;;
    --proxmox|--create-ct|"")
      if is_proxmox_host; then
        create_and_install_on_proxmox
      else
        # If not on Proxmox host, default to in-container install
        install_inside_container
      fi
      ;;
    *)
      die "Unknown argument: $1 (use --proxmox, --create-ct, or --install-only)"
      ;;
  esac
}

main "$@"
