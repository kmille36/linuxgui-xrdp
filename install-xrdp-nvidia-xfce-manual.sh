#!/usr/bin/env bash
# =============================================================================
# XRDP + NVIDIA GPU Acceleration + XFCE4 + Audio + Chrome — Full Install
#
# Combines:
#   - Nexarian/xrdp-nvidia-setup.sh (Nvidia nvenc, custom xrdp/xorgxrdp fork)
#   - kmille36/install-xrdp-xfce-manual.sh (XFCE4, audio, Chrome, user setup)
#
# Target: Ubuntu 22.04 (x86_64) with an NVIDIA GPU. Run as root or with sudo.
#
# Usage:
#   sudo RDP_USER=linux RDP_PASS=changeme ROOT_PASS=changeme bash install-xrdp-nvidia-xfce.sh
# =============================================================================

set -euo pipefail

# ---- Configuration ----
RDP_USER="${RDP_USER:-linux}"
RDP_PASS="${RDP_PASS:-linuxgui}"
ROOT_PASS="${ROOT_PASS:-linuxgui}"
BUILD_DIR="${BUILD_DIR:-/opt/xrdp-build}"

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

# ---- 2. System update ----
log "Updating system"
apt-get -y update
apt-get -y dist-upgrade
apt-get -y autoremove

# ---- 3. Install Nvidia Driver ----
log "Detecting Nvidia driver version and installing"

# Detect the currently-recommended driver version via ubuntu-drivers or nvidia-smi if already present.
# We query nvidia-smi first (covers the case where a partial driver is installed),
# then fall back to ubuntu-drivers to get the recommended version for this GPU.
NVIDIA_DRIVER_VERSION=""

if command -v nvidia-smi &>/dev/null; then
    # e.g. "Driver Version: 535.161.08" → "535.161.08"
    NVIDIA_DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]') || true
fi

if [[ -z "$NVIDIA_DRIVER_VERSION" ]]; then
    # Fall back to ubuntu-drivers to determine the recommended version
    apt-get install -y ubuntu-drivers-common
    NVIDIA_DRIVER_VERSION=$(ubuntu-drivers devices 2>/dev/null \
        | grep -oP 'nvidia-driver-\K[0-9]+' \
        | sort -rn | head -1) || true

    # ubuntu-drivers gives a major version (e.g. "535"); resolve to full x.y.z via apt
    if [[ -n "$NVIDIA_DRIVER_VERSION" ]]; then
        NVIDIA_DRIVER_VERSION=$(apt-cache show "nvidia-driver-${NVIDIA_DRIVER_VERSION}" 2>/dev/null \
            | grep -m1 '^Version:' | awk '{print $2}' | cut -d- -f1) || true
    fi
fi

if [[ -z "$NVIDIA_DRIVER_VERSION" ]]; then
    echo "[ERROR] Could not determine Nvidia driver version. Set NVIDIA_DRIVER_VERSION manually." >&2
    exit 1
fi

log "Using Nvidia driver version: ${NVIDIA_DRIVER_VERSION}"

# Build the official .run installer URL
# Format: https://us.download.nvidia.com/XFree86/Linux-x86_64/<version>/NVIDIA-Linux-x86_64-<version>.run
NVIDIA_RUN_URL="https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
NVIDIA_RUN_FILE="/tmp/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"

log "Downloading Nvidia driver installer: ${NVIDIA_RUN_URL}"
wget -q --show-progress -O "$NVIDIA_RUN_FILE" "$NVIDIA_RUN_URL"
chmod +x "$NVIDIA_RUN_FILE"

log "Installing Nvidia driver (no kernel module, no UI)"
# echo 1 accepts the license agreement non-interactively via stdin.
# --no-kernel-module: skip kernel module build (CUDA will handle the kernel side,
#                     or the module is already loaded / managed separately).
# --ui=none:          fully non-interactive, no ncurses/X11 UI.
echo 1 | "$NVIDIA_RUN_FILE" --no-kernel-module --ui=none

rm -f "$NVIDIA_RUN_FILE"

# Add user to GPU / input groups now that the driver has created them.
# Create any group that still doesn't exist (e.g. on minimal installs).
for grp in video tty render; do
    getent group "$grp" &>/dev/null || groupadd --system "$grp"
    usermod -a -G "$grp" "$RDP_USER"
done

# ---- 4. Install CUDA (Nvidia) ----
#log "Installing CUDA"
#cd ~
#wget https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
#dpkg -i cuda-keyring_1.1-1_all.deb
#apt-get update
#apt-get -y install cuda

# ---- 5. Base build dependencies ----
log "Installing some packages dev"
add-apt-repository universe -y
add-apt-repository multiverse -y
dpkg --add-architecture i386
apt-get update
apt install -y thunar htop nvtop pciutils xvkbd feh p7zip-full p7zip-rar xfce4-terminal libc6:amd64 libc6:i386 libegl1:amd64 libegl1:i386 libgbm1:amd64 libgbm1:i386 libgl1-mesa-dri:amd64 libgl1-mesa-dri:i386 libgl1:amd64 libgl1:i386 xvfb x11-xserver-utils libvulkan1 dbus-x11 mesa-utils pulseaudio xorg xserver-xorg x11-utils x11-apps
log "Installing base build dependencies"
apt-get -y install \
    git wget curl python3 python3-pip \
    autoconf automake libtool pkg-config build-essential \
    gcc g++ make nasm flex bison \
    sudo intltool xsltproc xutils-dev xutils python3-libxml2 \
    libssl-dev libpam0g-dev libjpeg-dev libx11-dev libxfixes-dev libxrandr-dev \
    libxml2-dev libfuse-dev libmp3lame-dev libpixman-1-dev xserver-xorg-dev \
    libjson-c-dev libsndfile1-dev libspeex-dev libspeexdsp-dev \
    libpulse-dev libpulse0 autopoint \
    libfdk-aac-dev libopus-dev libgbm-dev \
    libx264-dev \
    libssh2-1 libpango-1.0-0 libtelnet-dev \
    libimlib2-dev libvncserver-dev libwebp-dev \
    python3-numpy freerdp2-x11

# Install *turbojpeg (wildcard — may need separate step)
apt-get -y install libturbojpeg* || apt-get -y install libturbojpeg0-dev

# libepoxy (needs separate apt call on some Ubuntu versions)
apt-get -y install libepoxy-dev

# x264 runtime + libopenh264
apt-get -y install x264 libopenh264-dev || true

# ---- 6. X11 system prerequisites ----
log "Configuring X11 prerequisites"
apt-get -y install xorg xserver-xorg-legacy dbus-x11 tigervnc-standalone-server
apt-get -y remove --purge dbus-user-session || true

# Allow any user to start Xorg (required for xrdp)
tee /etc/X11/Xwrapper.config > /dev/null << 'EOL'
# Xwrapper.config (managed by xrdp-nvidia-xfce install script)
needs_root_rights=no
allowed_users=anybody
EOL

# ---- 7. Google Chrome ----
log "Installing Google Chrome"
CHROME_DEB="$(mktemp -d)/chrome.deb"
wget -q -O "$CHROME_DEB" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
apt-get install -y "$CHROME_DEB"
rm -f "$CHROME_DEB"
echo "google-chrome --disable-dev-shm-usage --no-sandbox" > /usr/bin/ggcr
chmod +x /usr/bin/ggcr

# ---- 8. Build xrdp (Nexarian fork — Nvidia nvenc support) ----
log "Building xrdp from Nexarian fork (nvenc + all codecs)"
mkdir -p "${BUILD_DIR}/xrdp"
cd "${BUILD_DIR}/xrdp"

git clone https://github.com/Nexarian/xrdp.git --branch mainline_merge xrdp-src
cd xrdp-src
./bootstrap
./configure \
    --enable-fuse \
    --enable-rfxcodec \
    --enable-pixman \
    --enable-mp3lame \
    --enable-sound \
    --enable-opus \
    --enable-fdkaac \
    --enable-x264 \
    --enable-openh264 \
    --enable-nvenc \
    --enable-ibus \
    --enable-ipv6 \
    --enable-jpeg \
    --enable-painter \
    --enable-utmp \
    --with-imlib2 \
    --with-freetype2 \
    --enable-vsock
make -j "$(nproc)" clean all
make install

# Symlinks so system finds xrdp binaries
ln -sf /usr/local/sbin/xrdp      /usr/sbin/xrdp      2>/dev/null || true
ln -sf /usr/local/sbin/xrdp-sesman /usr/sbin/xrdp-sesman 2>/dev/null || true

# Create xrdp system user if it doesn't exist
if ! id xrdp &>/dev/null; then
    adduser --system --group --no-create-home \
            --disabled-password --disabled-login \
            --home /run/xrdp xrdp
fi

# Fix permissions for TLS keys
chmod 640 /etc/xrdp/rsakeys.ini
chown root:xrdp /etc/xrdp/rsakeys.ini

# TLS certificate (snake-oil for self-signed)
log "Setting up TLS certificate for xrdp"
apt-get install -y apache2
make-ssl-cert generate-default-snakeoil || true
ln -sf /etc/ssl/certs/ssl-cert-snakeoil.pem  /etc/xrdp/cert.pem
ln -sf /etc/ssl/private/ssl-cert-snakeoil.key /etc/xrdp/key.pem
usermod -a -G ssl-cert xrdp

# ---- 9. Build xorgxrdp (Nexarian fork — Nvidia glamor + DRM support) ----
log "Building xorgxrdp from Nexarian fork (glamor/DRM)"
mkdir -p "${BUILD_DIR}/xorgxrdp"
cd "${BUILD_DIR}/xorgxrdp"

git clone https://github.com/Nexarian/xorgxrdp.git --branch mainline_merge xorgxrdp-src
cd xorgxrdp-src
./bootstrap
./configure --with-simd --enable-lrandr --enable-glamor
make -j "$(nproc)" clean all
make install

# Point sesman at the correct Xorg path
sed -i 's|^param=Xorg$|param=/usr/lib/xorg/Xorg|' /etc/xrdp/sesman.ini || true

# ---- 10. Nvidia GPU bus-ID configuration ----
log "Configuring Nvidia GPU in xorg_nvidia.conf"
BUS_ID=$(nvidia-smi --query-gpu=pci.bus --format=csv | sed -n '2 p' | xargs -I{} printf "%d\n" {})
sed -i -E 's/(BusID "PCI:)[[:digit:]]+(:0:0")/\1'"$BUS_ID"'\2/' /etc/X11/xrdp/xorg_nvidia.conf

# ---- 11. PulseAudio xrdp module ----
log "Building pulseaudio-module-xrdp"
apt-get install -y libpulse-dev lsb-release

mkdir -p "${BUILD_DIR}/xrdpaudio"
cd "${BUILD_DIR}/xrdpaudio"

git clone https://github.com/neutrinolabs/pulseaudio-module-xrdp.git
cd pulseaudio-module-xrdp
bash scripts/install_pulseaudio_sources_apt.sh
./bootstrap
./configure PULSE_DIR="$HOME/pulseaudio.src"
make -j "$(nproc)"
make install
bash /usr/libexec/pulseaudio-module-xrdp/load_pa_modules.sh || true

# ---- 12. Desktop environment (XFCE4) ----
log "Installing XFCE4"
apt-get install -y xfce4 xfce4-terminal xfce4-goodies

# ---- 13. Session scripts ----
log "Writing session startup scripts"

# xrdp startwm.sh — launch PulseAudio then XFCE4
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

# Per-user .xsession / .xsessionrc (written to the RDP user's home)
RDP_HOME="$(getent passwd "$RDP_USER" | cut -d: -f6)"
echo "startxfce4" > "${RDP_HOME}/.xsession"
chmod +x "${RDP_HOME}/.xsession"

cat > "${RDP_HOME}/.xsessionrc" << 'EOF'
export DESKTOP_SESSION=xfce
export XDG_CURRENT_DESKTOP=XFCE
EOF
chmod +x "${RDP_HOME}/.xsessionrc"
chown "${RDP_USER}:${RDP_USER}" "${RDP_HOME}/.xsession" "${RDP_HOME}/.xsessionrc"

# ---- 14. Enable and start xrdp ----
log "Enabling and starting xrdp"
if systemctl is-enabled xrdp &>/dev/null 2>&1; then
    systemctl enable xrdp
    systemctl restart xrdp
else
    # Fallback: run without systemd (e.g., inside a container)
    pkill xrdp-sesman 2>/dev/null || true
    pkill xrdp        2>/dev/null || true
    sleep 1
    setsid xrdp-sesman </dev/null >/dev/null 2>&1 &
    disown
    setsid xrdp -nodaemon </dev/null >/dev/null 2>&1 &
    disown
fi

# ---- Done ----
cat << INFO

=============================================================================
Installation complete!

XRDP is listening on port 3389.
Use any RDP client (Windows Remote Desktop, Remmina, etc.) to connect.

RDP Credentials:
  User : ${RDP_USER}
  Pass : ${RDP_PASS}

Root Credentials:
  User : root
  Pass : ${ROOT_PASS}

Tips:
  - On the remote terminal, run "ggcr" to open Google Chrome.
  - Nvidia GPU acceleration is enabled via Nexarian's xrdp/xorgxrdp fork.
  - Audio is routed through pulseaudio-module-xrdp.
  - Desktop: XFCE4
=============================================================================
INFO
