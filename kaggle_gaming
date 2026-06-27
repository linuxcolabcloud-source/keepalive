#!/bin/bash
# Kaggle GPU Desktop — Xvfb + Parsec + Tailscale + VirtualGL + Minecraft
# Usage: chmod +x kaggle_parsec_clean.sh && ./kaggle_parsec_clean.sh all

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
sep()  { echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }

detect_env() {
    sep
    info "Phát hiện môi trường..."
    
    if nvidia-smi &>/dev/null 2>&1; then
        log "GPU NVIDIA được phát hiện"
        HAS_GPU=true
    else
        warn "Không tìm thấy GPU NVIDIA"
        HAS_GPU=false
    fi
    export HAS_GPU
    
    if [ -d /kaggle ]; then
        ENV_TYPE="kaggle"
        log "Môi trường: Kaggle"
    elif [ -d /content ]; then
        ENV_TYPE="colab"
        log "Môi trường: Google Colab"
    else
        ENV_TYPE="other"
    fi
    export ENV_TYPE
}

phase_1_base() {
    sep
    info "PHASE 1: Xvfb + Xfce4"
    
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    
    apt-get install -y -qq \
        xvfb x11-xserver-utils xserver-xorg-video-dummy \
        xfce4 xfce4-terminal xfce4-goodies \
        dbus-x11 \
        pulseaudio pavucontrol alsa-utils \
        wget curl git unzip python3 python3-pip \
        mesa-utils libglu1-mesa \
        fonts-dejavu fonts-liberation \
        libegl1 libgles2 2>/dev/null
    
    pkill -f "Xvfb :99" 2>/dev/null || true
    pkill -f xfce4-session 2>/dev/null || true
    sleep 1
    
    Xvfb :99 -screen 0 1920x1080x24 \
        -ac +extension GLX +extension RANDR +extension RENDER \
        -dpi 96 -noreset &
    export DISPLAY=:99
    sleep 3
    
    if ! xdpyinfo -display :99 &>/dev/null; then
        err "Xvfb không khởi động được"
    fi
    log "Xvfb :99 đã khởi động"
    
    dbus-launch --sh-syntax > /tmp/dbus.env 2>/dev/null && source /tmp/dbus.env || true
    DISPLAY=:99 startxfce4 &>/tmp/xfce4.log &
    sleep 4
    log "Xfce4 đã khởi động"
    
    pulseaudio --start --exit-idle-time=-1 &>/tmp/pulse.log || true
    sleep 1
    log "PulseAudio đã khởi động"
    
    echo "export DISPLAY=:99" >> /etc/environment
}

phase_2_parsec() {
    sep
    info "PHASE 2: Parsec daemon"
    
    PARSEC_DEB_URL="https://builds.parsec.app/package/parsec-linux.deb"
    if ! command -v parsecd &>/dev/null; then
        wget -q "$PARSEC_DEB_URL" -O /tmp/parsec.deb || \
            err "Không tải được Parsec"
        dpkg -i /tmp/parsec.deb 2>/dev/null || \
            apt-get install -f -y -qq 2>/dev/null
        log "Parsec đã cài"
    else
        log "Parsec đã có sẵn"
    fi
    
    mkdir -p /root/.config/parsec
    cat > /root/.config/parsec/config.txt <<'EOF'
app_host=1
app_first_run=0
app_daemon=1
encoder_h265=0
encoder_bitrate=20
encoder_fps=60
server_resolution_x=1920
server_resolution_y=1080
EOF

    sep
    if [ -n "$PARSEC_TEAM_ID" ] && [ -n "$PARSEC_TEAM_COMPUTER_KEY" ]; then
        log "Dùng Team credentials"
        DISPLAY=:99 parsecd \
            team_id="$PARSEC_TEAM_ID" \
            team_computer_key="$PARSEC_TEAM_COMPUTER_KEY" \
            &>/tmp/parsec.log &
        sleep 5
        log "Parsec đang chạy"
    else
        warn "Nhập Team ID + Computer Key:"
        echo -n "  Team ID       : "
        read -r PARSEC_TEAM_ID
        echo -n "  Computer Key  : "
        read -r PARSEC_TEAM_COMPUTER_KEY
        
        if [ -z "$PARSEC_TEAM_ID" ] || [ -z "$PARSEC_TEAM_COMPUTER_KEY" ]; then
            warn "Bỏ qua Parsec — chạy lại sau"
            return
        fi
        
        export PARSEC_TEAM_ID PARSEC_TEAM_COMPUTER_KEY
        DISPLAY=:99 parsecd \
            team_id="$PARSEC_TEAM_ID" \
            team_computer_key="$PARSEC_TEAM_COMPUTER_KEY" \
            &>/tmp/parsec.log &
        sleep 5
        log "Parsec đang chạy"
    fi
}

phase_3_tailscale() {
    sep
    info "PHASE 3: Tailscale"
    
    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
        log "Tailscale đã cài"
    else
        log "Tailscale đã có"
    fi
    
    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    sysctl -p -q 2>/dev/null || true
    
    if ! pgrep tailscaled &>/dev/null; then
        mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
        nohup tailscaled --state=/var/lib/tailscale/tailscaled.state \
            2>/tmp/tailscaled.log &
        sleep 2
        log "tailscaled đã khởi động"
    fi
    
    sep
    info "Đang lấy link đăng nhập Tailscale..."
    
    tailscale up --accept-routes --hostname=kaggle-gpu --timeout=0 \
        2>&1 | tee /tmp/tailscale_auth.log &
    TS_UP_PID=$!
    
    TS_URL=""
    for i in $(seq 1 15); do
        TS_URL=$(grep -oE 'https://login\.tailscale\.com/[^ ]+' \
            /tmp/tailscale_auth.log 2>/dev/null | head -1)
        [ -n "$TS_URL" ] && break
        sleep 1
    done
    
    if [ -n "$TS_URL" ]; then
        echo -e "${CYAN}┌────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│   MỞ LINK ĐỂ ĐĂNG NHẬP TAILSCALE   │${NC}"
        echo -e "${CYAN}└────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  ${YELLOW}${TS_URL}${NC}"
        echo ""
        
        for i in $(seq 1 24); do
            if tailscale status 2>/dev/null | grep -q "kaggle-gpu\|100\."; then
                log "✅ Tailscale kết nối thành công"
                break
            fi
            echo -ne "  Chờ... ${i}/24\r"
            sleep 5
        done
        echo ""
    fi
    
    kill $TS_UP_PID 2>/dev/null || true
}

phase_4_vgl() {
    sep
    info "PHASE 4: VirtualGL"
    
    VGL_VER="3.1.1"
    VGL_DEB="virtualgl_${VGL_VER}_amd64.deb"
    VGL_URL="https://github.com/VirtualGL/virtualgl/releases/download/${VGL_VER}/${VGL_DEB}"
    
    if ! command -v vglrun &>/dev/null; then
        wget -q "$VGL_URL" -O /tmp/virtualgl.deb || \
            err "Không tải được VirtualGL"
        dpkg -i /tmp/virtualgl.deb 2>/dev/null || apt-get install -f -y -qq
        log "VirtualGL đã cài"
    else
        log "VirtualGL đã có"
    fi
    
    if [ "$HAS_GPU" = "true" ] && ls /dev/dri/card* &>/dev/null 2>&1; then
        export VGL_DISPLAY=/dev/dri/card0
        log "VirtualGL → GPU: /dev/dri/card0"
    else
        export VGL_DISPLAY=:99
        warn "VirtualGL → CPU fallback (Xvfb)"
    fi
    
    export VGL_READBACK=pbo
    export VGL_COMPRESS=jpeg
    export VGL_QUAL=90
}

phase_5_minecraft() {
    sep
    info "PHASE 5: Java + Minecraft"
    
    if ! java -version 2>&1 | grep -qE "21|17"; then
        apt-get install -y -qq openjdk-21-jdk 2>/dev/null || \
        apt-get install -y -qq openjdk-17-jdk 2>/dev/null
    fi
    log "Java: $(java -version 2>&1 | head -1)"
    
    mkdir -p /opt/minecraft
    
    wget -q "https://github.com/PrismLauncher/PrismLauncher/releases/latest/download/PrismLauncher-Linux-x86_64.AppImage" \
        -O /opt/minecraft/PrismLauncher.AppImage || true
    [ -f /opt/minecraft/PrismLauncher.AppImage ] && \
        chmod +x /opt/minecraft/PrismLauncher.AppImage && \
        apt-get install -y -qq fuse libfuse2 2>/dev/null || true
    
    cat > /opt/minecraft/run.sh <<'MCRUN'
#!/bin/bash
export DISPLAY=:99
export VGL_DISPLAY=/dev/dri/card0
vglrun /opt/minecraft/PrismLauncher.AppImage --no-sandbox &
MCRUN
    chmod +x /opt/minecraft/run.sh
    
    log "Minecraft sẵn sàng: /opt/minecraft/run.sh"
}

main() {
    PHASE="${1:-all}"
    
    detect_env
    
    case "$PHASE" in
        all)
            phase_1_base
            phase_2_parsec
            phase_3_tailscale
            phase_4_vgl
            phase_5_minecraft
            ;;
        1|1_base)      phase_1_base ;;
        2|2_parsec)    phase_2_parsec ;;
        3|3_tailscale) phase_3_tailscale ;;
        4|4_vgl)       phase_4_vgl ;;
        5|5_minecraft) phase_5_minecraft ;;
        *)
            echo "Usage: $0 [all|1|2|3|4|5]"
            exit 1
            ;;
    esac
    
    sep
    log "HOÀN TẤT!"
}

main "$@"
