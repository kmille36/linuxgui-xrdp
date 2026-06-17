#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# XRDP + XFCE4 + Google Chrome remote desktop, built from source.
# Direct-on-host equivalent of the Dockerfile + start.sh (no Docker).
# Target: Ubuntu (matches `FROM ubuntu:latest`). Run as root.
#
#   sudo RDP_USER=linux RDP_PASS=changeme ROOT_PASS=changeme \
#        bash install-xrdp-xfce.sh
# =====================================================================

RDP_USER="${RDP_USER:-linux}"
RDP_PASS="${RDP_PASS:-linuxgui}"
ROOT_PASS="${ROOT_PASS:-linuxgui}"
BUILD_DIR="${BUILD_DIR:-/opt/xrdp-build}"
XRDP_VER="0.10.5"

if [[ "$EUID" -ne 0 ]]; then
  echo "Run this as root: sudo bash $0" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
log() { echo -e "\n==> $*\n"; }

# ---- 1. User setup ----
log "Setting root password and creating user '$RDP_USER'"
echo "root:${ROOT_PASS}" | chpasswd
if ! id "$RDP_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$RDP_USER"
fi
echo "${RDP_USER}:${RDP_PASS}" | chpasswd
mkdir -p /etc/sudoers.d
usermod -aG sudo "$RDP_USER"
echo "${RDP_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${RDP_USER}"
chmod 440 "/etc/sudoers.d/${RDP_USER}"

# ---- 2. Base packages ----
log "Installing base packages"
apt update -y
apt upgrade -y
apt install -y git wget curl python3 python3-pip autoconf automake build-essential sudo
apt install -y freerdp2-x11 libssh2-1 libssl-dev libpango-1.0-0 libtelnet-dev \
  libimlib2-dev libvncserver-dev pulseaudio libwebp-dev
apt install -y python3-numpy

# ---- 3. Google Chrome ----
log "Installing Google Chrome"
CHROME_DEB="$(mktemp -d)/chrome.deb"
wget -q -O "$CHROME_DEB" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
apt install -y "$CHROME_DEB"
rm -f "$CHROME_DEB"
echo "google-chrome --disable-dev-shm-usage --no-sandbox" > /usr/bin/ggcr
chmod +x /usr/bin/ggcr

# ---- 4. Build xrdp ----
log "Building xrdp ${XRDP_VER} from source"
mkdir -p "${BUILD_DIR}/xrdp"
cd "${BUILD_DIR}/xrdp"
wget -q -O "xrdp-${XRDP_VER}.tar.gz" \
  "https://github.com/neutrinolabs/xrdp/releases/download/v${XRDP_VER}/xrdp-${XRDP_VER}.tar.gz"
tar xzf "xrdp-${XRDP_VER}.tar.gz"
cd "xrdp-${XRDP_VER}"
wget -q -O dec.sh \
  https://raw.githubusercontent.com/neutrinolabs/xrdp/refs/heads/devel/scripts/install_xrdp_build_dependencies_with_apt.sh
bash dec.sh
apt install -y libfuse3-dev libfdk-aac-dev libopus-dev libmp3lame-dev x264 libx264-dev libopenh264-dev

./bootstrap
./configure \
  --enable-ibus --enable-ipv6 --enable-jpeg --enable-fuse --enable-mp3lame \
  --enable-fdkaac --enable-opus --enable-rfxcodec --enable-painter \
  --enable-pixman --enable-utmp --with-imlib2 --with-freetype2 \
  --enable-tests --enable-x264 --enable-openh264 --enable-vsock

make -j"$(nproc)"
make install

ln -sf /usr/local/sbin/xrdp /usr/sbin/xrdp
ln -sf /usr/local/sbin/xrdp-sesman /usr/sbin/xrdp-sesman

if ! id xrdp &>/dev/null; then
  adduser --system --group --no-create-home --disabled-password --disabled-login \
    --home /run/xrdp xrdp
fi

sed -i '/runtime_user=xrdp/ s/^[[:space:]]*#//; /runtime_group=xrdp/ s/^[[:space:]]*#//' /etc/xrdp/xrdp.ini
sed -i '/^#SessionSockdirGroup=xrdp$/ s/^#//' /etc/xrdp/sesman.ini
chmod 640 /etc/xrdp/rsakeys.ini
chown root:xrdp /etc/xrdp/rsakeys.ini

log "Setting up TLS cert for xrdp"
apt install -y apache2
make-ssl-cert generate-default-snakeoil || true
ln -sf /etc/ssl/certs/ssl-cert-snakeoil.pem /etc/xrdp/cert.pem
ln -sf /etc/ssl/private/ssl-cert-snakeoil.key /etc/xrdp/key.pem
usermod -a -G ssl-cert xrdp

# ---- 5. Build xorgxrdp ----
log "Building xorgxrdp ${XRDP_VER}"
mkdir -p "${BUILD_DIR}/xorgxrdp"
cd "${BUILD_DIR}/xorgxrdp"
wget -q -O "xorgxrdp-${XRDP_VER}.tar.gz" \
  "https://github.com/neutrinolabs/xorgxrdp/releases/download/v${XRDP_VER}/xorgxrdp-${XRDP_VER}.tar.gz"
tar xzf "xorgxrdp-${XRDP_VER}.tar.gz"
rm -rf xorgxrdp
mv "xorgxrdp-${XRDP_VER}" xorgxrdp
cd xorgxrdp
wget -q -O install_xorgxrdp_build_dependencies_with_apt.sh \
  https://raw.githubusercontent.com/neutrinolabs/xorgxrdp/refs/heads/devel/scripts/install_xorgxrdp_build_dependencies_with_apt.sh
bash install_xorgxrdp_build_dependencies_with_apt.sh
./bootstrap
./configure --enable-glamor
make -j"$(nproc)"
make install
sed -i 's|^param=Xorg$|param=/usr/lib/xorg/Xorg|' /etc/xrdp/sesman.ini

# ---- 6. xrdp pulseaudio module ----
log "Building pulseaudio-module-xrdp"
mkdir -p "${BUILD_DIR}/xrdpaudio"
cd "${BUILD_DIR}/xrdpaudio"
apt install -y libpulse-dev lsb-release
if [[ ! -d pulseaudio-module-xrdp ]]; then
  git clone https://github.com/neutrinolabs/pulseaudio-module-xrdp.git
fi
cd pulseaudio-module-xrdp
bash scripts/install_pulseaudio_sources_apt.sh
./bootstrap
./configure PULSE_DIR="$HOME/pulseaudio.src"
make -j"$(nproc)"
make install
bash /usr/libexec/pulseaudio-module-xrdp/load_pa_modules.sh || true

# ---- 7. Desktop environment ----
log "Installing XFCE4"
apt install -y xfce4 xfce4-terminal xfce4-goodies tigervnc-standalone-server dbus-x11

# ---- 8. Session startup script ----
log "Writing /etc/xrdp/startwm.sh"
cat > /etc/xrdp/startwm.sh << 'EOF'
#!/bin/sh
case "$(whoami)" in
  root)
    pulseaudio --system >/dev/null 2>&1 &
    pulseaudio >/dev/null 2>&1 &
    ;;
  *)
    pulseaudio --start >/dev/null 2>&1
    ;;
esac
exec startxfce4
EOF
chmod +x /etc/xrdp/startwm.sh

log "Install finished."

# ---- 9. Start (equivalent of start.sh) ----
pkill xrdp-sesman 2>/dev/null || true
pkill xrdp 2>/dev/null || true
sleep 1

# setsid + disown so xrdp survives after this script/SSH session exits.
setsid xrdp-sesman </dev/null >/dev/null 2>&1 &
disown
setsid xrdp -nodaemon </dev/null >/dev/null 2>&1 &
disown

cat << INFO
Can open Google Chrome by executing "ggcr" on the remote terminal
XRDP run at port 3389

Credentials:
User: ${RDP_USER}
Pass: ${RDP_PASS}
Root Credentials:
User: root
Pass: ${ROOT_PASS}
INFO
