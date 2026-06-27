#!/bin/bash
# =============================================================================
# GPU Desktop Setup: Xfce + Xvfb + Parsec + Tailscale + VirtualGL + Minecraft
# Dành cho Kaggle (ưu tiên) / Google Colab — Ubuntu, NVIDIA GPU
# Parsec không cần Xorg thật → tỉ lệ thành công ~55-65%
# =============================================================================
# CÁCH DÙNG:
#   bash kaggle_parsec_desktop.sh [phase]
#   phase: all | 1_base | 2_parsec | 3_tailscale | 4_vgl | 5_minecraft
#   Hoặc chạy toàn bộ: bash kaggle_parsec_desktop.sh all
#
# YÊU CẦU TRƯỚC KHI CHẠY:
#   - Tài khoản Parsec (free): https://parsec.app
#   - Lấy PARSEC_TEAM_ID + PARSEC_TEAM_COMPUTER_KEY từ:
#     https://parsec.app/profile → Warp (hoặc Team tab)
#   - Set secret trong Kaggle: Add-ons → Secrets
# =============================================================================

set -euo pipefail

# ─── Màu sắc terminal ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
sep()  { echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }

# ─── Kiểm tra môi trường ─────────────────────────────────────────────────────
detect_env() {
    sep
    info "Phát hiện môi trường..."

    if nvidia-smi &>/dev/null 2>&1; then
        log "GPU NVIDIA được phát hiện"
        nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || true
        HAS_GPU=true
    else
        warn "Không tìm thấy GPU NVIDIA — VirtualGL sẽ dùng CPU fallback"
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
        warn "Môi trường không xác định — tiếp tục..."
    fi
    export ENV_TYPE

    # Đọc Parsec credentials từ env hoặc Kaggle Secrets
    PARSEC_TEAM_ID="${PARSEC_TEAM_ID:-}"
    PARSEC_TEAM_COMPUTER_KEY="${PARSEC_TEAM_COMPUTER_KEY:-}"

    # Thử đọc từ Kaggle Secrets (nếu đã add)
    if [ -z "$PARSEC_TEAM_ID" ] && [ -f /kaggle/input/parsec-creds/team_id ]; then
        PARSEC_TEAM_ID=$(cat /kaggle/input/parsec-creds/team_id)
    fi
    if [ -z "$PARSEC_TEAM_COMPUTER_KEY" ] && [ -f /kaggle/input/parsec-creds/computer_key ]; then
        PARSEC_TEAM_COMPUTER_KEY=$(cat /kaggle/input/parsec-creds/computer_key)
    fi

    export PARSEC_TEAM_ID PARSEC_TEAM_COMPUTER_KEY
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1 — Xvfb + Xfce4 + noVNC
# Parsec không cần Xorg thật — Xvfb là đủ để chạy desktop
# noVNC để xem màn hình qua browser trong lúc chờ Parsec kết nối
# ═══════════════════════════════════════════════════════════════════════════════
phase_1_base() {
    sep
    info "PHASE 1: Cài Xvfb + Xfce4 + noVNC"

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
        libegl1 libgles2 \
        2>/dev/null

    # ── Khởi động Xvfb ───────────────────────────────────────────────────────
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
    log "Xvfb :99 đã khởi động (1920x1080x24)"

    # ── Xfce4 ────────────────────────────────────────────────────────────────
    dbus-launch --sh-syntax > /tmp/dbus.env 2>/dev/null && source /tmp/dbus.env || true
    DISPLAY=:99 startxfce4 &>/tmp/xfce4.log &
    sleep 4
    log "Xfce4 đã khởi động"

    # ── PulseAudio (Parsec cần audio) ────────────────────────────────────────
    pulseaudio --start --exit-idle-time=-1 &>/tmp/pulse.log || true
    sleep 1
    log "PulseAudio đã khởi động"

    echo "export DISPLAY=:99" >> /etc/environment
    echo "DISPLAY=:99" > /tmp/display.env
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2 — Parsec (thay thế Sunshine/Moonlight)
#
# Tại sao Parsec tốt hơn Sunshine trên Colab/Kaggle?
#   - Không cần Xorg thật / physical display
#   - Tự xử lý capture từ framebuffer
#   - Có sẵn GPU encode (NVENC) qua driver riêng
#   - Chạy như daemon, không cần tty
# ═══════════════════════════════════════════════════════════════════════════════
phase_2_parsec() {
    sep
    info "PHASE 2: Cài Parsec"

    # ── Tải Parsec Linux server (parsecd) ────────────────────────────────────
    PARSEC_DEB_URL="https://builds.parsec.app/package/parsec-linux.deb"
    if ! command -v parsecd &>/dev/null; then
        wget -q "$PARSEC_DEB_URL" -O /tmp/parsec.deb || \
            err "Không tải được Parsec — kiểm tra kết nối mạng"
        dpkg -i /tmp/parsec.deb 2>/dev/null || \
            apt-get install -f -y -qq 2>/dev/null
        log "Parsec đã cài: $(parsecd --version 2>/dev/null || echo 'installed')"
    else
        log "Parsec đã có sẵn"
    fi

    # ── Cấu hình Parsec ──────────────────────────────────────────────────────
    mkdir -p /root/.config/parsec
    cat > /root/.config/parsec/config.txt <<PARSEC_CONF
app_host=1
app_first_run=0
app_daemon=1
encoder_h265=0
encoder_bitrate=20
encoder_fps=60
server_resolution_x=1920
server_resolution_y=1080
server_gpu=0
PARSEC_CONF

    # ── Xác thực Parsec ──────────────────────────────────────────────────────
    sep
    if [ -n "$PARSEC_TEAM_ID" ] && [ -n "$PARSEC_TEAM_COMPUTER_KEY" ]; then
        log "Dùng Team credentials từ environment"
        _start_parsec_team
    elif [ -n "${PARSEC_SSO_TOKEN:-}" ]; then
        log "Dùng SSO Bearer Token"
        _start_parsec_sso
    else
        warn "Không tìm thấy credentials — chuyển sang nhập thủ công..."
        _start_parsec_manual
    fi
}

# ── Parsec Team/Warp (không cần tương tác) ───────────────────────────────────
_start_parsec_team() {
    info "Khởi động Parsec với Team credentials..."

    DISPLAY=:99 parsecd \
        team_id="$PARSEC_TEAM_ID" \
        team_computer_key="$PARSEC_TEAM_COMPUTER_KEY" \
        &>/tmp/parsec.log &
    sleep 5

    if pgrep -x parsecd &>/dev/null; then
        log "Parsec đang chạy (Team mode)"
        info "Mở Parsec app trên máy → máy 'KaggleGPU' sẽ hiện trong danh sách"
    else
        warn "Parsec không khởi động — xem log: /tmp/parsec.log"
        tail -10 /tmp/parsec.log || true
    fi
}

# ── Parsec thủ công (hỏi Team ID + Computer Key) ─────────────────────────────
_start_parsec_manual() {
    sep
    echo -e "${CYAN}┌──────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│           ĐĂNG NHẬP PARSEC                       │${NC}"
    echo -e "${CYAN}└──────────────────────────────────────────────────┘${NC}"
    echo ""
    info "Cách lấy Team ID + Computer Key:"
    echo ""
    echo -e "  1. Vào ${YELLOW}https://parsec.app${NC} → đăng nhập"
    echo -e "  2. Click avatar → ${YELLOW}Profile${NC}"
    echo -e "  3. Tìm tab ${YELLOW}Warp${NC}"
    echo -e "  4. Nhấn ${YELLOW}Get Computer Key${NC}"
    echo -e "  5. Copy 2 giá trị bên dưới"
    echo ""

    echo -n "  Nhập Team ID       : "
    read -r PARSEC_TEAM_ID
    echo -n "  Nhập Computer Key  : "
    read -r PARSEC_TEAM_COMPUTER_KEY

    if [ -z "$PARSEC_TEAM_ID" ] || [ -z "$PARSEC_TEAM_COMPUTER_KEY" ]; then
        warn "Chưa nhập đủ — bỏ qua Parsec"
        info "Chạy lại sau: bash $0 2_parsec"
        return
    fi

    export PARSEC_TEAM_ID PARSEC_TEAM_COMPUTER_KEY
    _start_parsec_team
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3 — Tailscale (dự phòng nếu Parsec relay chậm)
# Parsec tự có relay server nên Tailscale không bắt buộc
# Nhưng nếu muốn kết nối trực tiếp P2P → Tailscale giúp giảm lag
# ═══════════════════════════════════════════════════════════════════════════════
phase_3_tailscale() {
    sep
    info "PHASE 3: Cài Tailscale (đăng nhập bằng link)"

    if ! command -v tailscale &>/dev/null; then
        curl -fsSL https://tailscale.com/install.sh | sh
        log "Tailscale đã cài"
    else
        log "Tailscale đã có: $(tailscale version)"
    fi

    echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
    echo 'net.ipv6.conf.all.forwarding = 1' >> /etc/sysctl.conf
    sysctl -p -q 2>/dev/null || true

    # Khởi động daemon
    if ! pgrep tailscaled &>/dev/null; then
        mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
        nohup tailscaled --state=/var/lib/tailscale/tailscaled.state \
            2>/tmp/tailscaled.log &
        sleep 2
        log "tailscaled đã khởi động"
    fi

    sep
    info "Đang lấy link đăng nhập Tailscale..."
    echo ""

    # Chạy tailscale up và bắt link ra stdout
    # --timeout=0 để không tự thoát trước khi user kịp login
    tailscale up \
        --accept-routes \
        --hostname=kaggle-gpu \
        --timeout=0 \
        2>&1 | tee /tmp/tailscale_auth.log &
    TS_UP_PID=$!

    # Đợi link xuất hiện trong log (tối đa 15 giây)
    TS_URL=""
    for i in $(seq 1 15); do
        TS_URL=$(grep -oE 'https://login\.tailscale\.com/[^ ]+' \
            /tmp/tailscale_auth.log 2>/dev/null | head -1)
        [ -n "$TS_URL" ] && break
        sleep 1
    done

    if [ -n "$TS_URL" ]; then
        echo -e "${CYAN}┌──────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│         MỞ LINK NÀY ĐỂ ĐĂNG NHẬP TAILSCALE     │${NC}"
        echo -e "${CYAN}└──────────────────────────────────────────────────┘${NC}"
        echo ""
        echo -e "  ${YELLOW}${TS_URL}${NC}"
        echo ""
        info "Sau khi đăng nhập trên browser → quay lại đây"
        info "Script sẽ tự tiếp tục khi Tailscale kết nối xong"
        echo ""

        # Đợi Tailscale kết nối (tối đa 120 giây)
        CONNECTED=false
        for i in $(seq 1 24); do
            if tailscale status 2>/dev/null | grep -q "kaggle-gpu\|100\."; then
                CONNECTED=true
                break
            fi
            echo -ne "  Chờ kết nối... ${i}/24\r"
            sleep 5
        done

        echo ""
        if [ "$CONNECTED" = "true" ]; then
            TS_IP=$(tailscale ip -4 2>/dev/null || echo "không lấy được")
            log "✅ Tailscale đã kết nối!"
            log "IP Tailscale: ${TS_IP}"
            echo ""
            info "Dùng IP này trong Parsec nếu muốn kết nối trực tiếp (giảm lag)"
        else
            warn "Chưa thấy kết nối sau 120s — kiểm tra đã mở link chưa"
            warn "Chạy thủ công: tailscale up --hostname=kaggle-gpu"
        fi
    else
        warn "Không lấy được link — xem log đầy đủ:"
        cat /tmp/tailscale_auth.log
        echo ""
        info "Thử chạy thủ công:"
        echo -e "  ${YELLOW}tailscale up --hostname=kaggle-gpu${NC}"
    fi

    # Dọn background process
    kill $TS_UP_PID 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4 — VirtualGL (ép GPU render cho Minecraft qua Xvfb)
# ═══════════════════════════════════════════════════════════════════════════════
phase_4_vgl() {
    sep
    info "PHASE 4: Cài VirtualGL"

    VGL_VER="3.1.1"
    VGL_DEB="virtualgl_${VGL_VER}_amd64.deb"
    VGL_URL="https://github.com/VirtualGL/virtualgl/releases/download/${VGL_VER}/${VGL_DEB}"

    if ! command -v vglrun &>/dev/null; then
        wget -q "$VGL_URL" -O /tmp/virtualgl.deb || \
            err "Không tải được VirtualGL"
        dpkg -i /tmp/virtualgl.deb 2>/dev/null || \
            apt-get install -f -y -qq
        log "VirtualGL đã cài"
    else
        log "VirtualGL đã có: $(vglrun -v 2>/dev/null | head -1)"
    fi

    # Cấu hình VGL display
    if [ "$HAS_GPU" = "true" ] && ls /dev/dri/card* &>/dev/null 2>&1; then
        export VGL_DISPLAY=/dev/dri/card0
        export VGL_READBACK=pbo
        log "VirtualGL → GPU: /dev/dri/card0"
    else
        export VGL_DISPLAY=:99
        warn "VirtualGL → CPU fallback (Xvfb)"
    fi

    export VGL_COMPRESS=jpeg
    export VGL_QUAL=90

    cat >> /etc/environment <<VGLENV
VGL_DISPLAY=${VGL_DISPLAY}
VGL_READBACK=pbo
VGL_COMPRESS=jpeg
VGL_QUAL=90
VGLENV

    # Test nhanh
    DISPLAY=:99 vglrun glxinfo 2>/dev/null | grep -E "OpenGL renderer|vendor" || \
        warn "glxinfo test thất bại — tiếp tục..."

    log "VirtualGL sẵn sàng"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5 — Java + Minecraft
# ═══════════════════════════════════════════════════════════════════════════════
phase_5_minecraft() {
    sep
    info "PHASE 5: Cài Java + Minecraft Launchers"

    # Java 21
    if ! java -version 2>&1 | grep -qE "21|17"; then
        apt-get install -y -qq openjdk-21-jdk 2>/dev/null || \
        apt-get install -y -qq openjdk-17-jdk 2>/dev/null
    fi
    log "Java: $(java -version 2>&1 | head -1)"

    mkdir -p /opt/minecraft

    # PrismLauncher AppImage
    info "Tải PrismLauncher..."
    wget -q "https://github.com/PrismLauncher/PrismLauncher/releases/latest/download/PrismLauncher-Linux-x86_64.AppImage" \
        -O /opt/minecraft/PrismLauncher.AppImage || warn "Không tải được PrismLauncher"
    [ -f /opt/minecraft/PrismLauncher.AppImage ] && \
        chmod +x /opt/minecraft/PrismLauncher.AppImage && \
        apt-get install -y -qq fuse libfuse2 2>/dev/null || true

    # ATLauncher fallback
    info "Tải ATLauncher..."
    wget -q "https://download.atlauncher.com/ATLauncher-latest.jar" \
        -O /opt/minecraft/ATLauncher.jar 2>/dev/null || true

    # Script chạy Minecraft với VGL qua Parsec
    cat > /opt/minecraft/run_minecraft_gpu.sh <<'MCRUN'
#!/bin/bash
export DISPLAY=:99
export VGL_DISPLAY=/dev/dri/card0
export VGL_READBACK=pbo
export VGL_COMPRESS=jpeg

echo "=== GPU Info ==="
vglrun glxinfo 2>/dev/null | grep "OpenGL renderer" || echo "CPU fallback"
echo "================"

LAUNCHER="${1:-prism}"
case "$LAUNCHER" in
    prism)
        echo "Khởi động PrismLauncher + VirtualGL..."
        vglrun /opt/minecraft/PrismLauncher.AppImage --no-sandbox &
        ;;
    atlauncher)
        echo "Khởi động ATLauncher + VirtualGL..."
        vglrun java -Xmx2G -jar /opt/minecraft/ATLauncher.jar &
        ;;
    vanilla)
        MC_JAR="${2:-/opt/minecraft/minecraft.jar}"
        echo "Chạy Vanilla: $MC_JAR"
        vglrun java \
            -Xms1G -Xmx4G \
            -XX:+UseG1GC -XX:+ParallelRefProcEnabled \
            -XX:MaxGCPauseMillis=200 \
            -XX:+UnlockExperimentalVMOptions \
            -XX:+DisableExplicitGC -XX:+AlwaysPreTouch \
            -XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 \
            -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 \
            -jar "$MC_JAR" &
        ;;
    *)
        echo "Dùng: $0 [prism|atlauncher|vanilla]"
        exit 1
        ;;
esac
echo "Minecraft đang khởi động... (xem qua Parsec)"
MCRUN
    chmod +x /opt/minecraft/run_minecraft_gpu.sh

    log "Minecraft launchers đã cài tại /opt/minecraft/"
    info "Chạy: bash /opt/minecraft/run_minecraft_gpu.sh prism"
}

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER SCRIPTS
# ═══════════════════════════════════════════════════════════════════════════════
create_helper_scripts() {
    sep
    info "Tạo script tiện ích..."

    cat > /usr/local/bin/gpu-desktop-status <<'STATUS'
#!/bin/bash
echo "══ GPU Desktop Status (Parsec) ══"
echo "— Xvfb:      $(pgrep -x Xvfb    &>/dev/null && echo '✅ RUNNING' || echo '❌ STOPPED')"
echo "— Xfce:      $(pgrep -f xfce4   &>/dev/null && echo '✅ RUNNING' || echo '❌ STOPPED')"
echo "— Parsec:    $(pgrep -x parsecd  &>/dev/null && echo '✅ RUNNING' || echo '❌ STOPPED')"
echo "— Tailscale: $(tailscale status 2>/dev/null | head -1 || echo 'NOT CONNECTED')"
echo ""
echo "— Tailscale IP : $(tailscale ip -4 2>/dev/null || echo 'chưa kết nối')"
echo "— Parsec log   : tail -f /tmp/parsec.log"
echo ""
echo "— GPU:"
nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader 2>/dev/null || echo "  Không có NVIDIA GPU"
STATUS
    chmod +x /usr/local/bin/gpu-desktop-status

    cat > /usr/local/bin/gpu-desktop-restart <<'RESTART'
#!/bin/bash
pkill -x parsecd 2>/dev/null; pkill -f "Xvfb :99" 2>/dev/null
pkill -f xfce4-session 2>/dev/null
sleep 2
export DISPLAY=:99
Xvfb :99 -screen 0 1920x1080x24 -ac +extension GLX -noreset &
sleep 3; startxfce4 &>/tmp/xfce4.log &
sleep 3
if [ -n "${PARSEC_TEAM_ID:-}" ]; then
    DISPLAY=:99 parsecd team_id="$PARSEC_TEAM_ID" \
        team_computer_key="$PARSEC_TEAM_COMPUTER_KEY" &>/tmp/parsec.log &
else
    echo "Parsec cần credentials — chạy thủ công:"
    echo "  parsecd team_id=XXX team_computer_key=YYY &"
fi
echo "Đã restart tất cả dịch vụ"
RESTART
    chmod +x /usr/local/bin/gpu-desktop-restart

    log "Lệnh tiện ích:"
    info "  gpu-desktop-status   — xem trạng thái"
    info "  gpu-desktop-restart  — restart tất cả"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
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
            create_helper_scripts
            ;;
        1_base)      phase_1_base ;;
        2_parsec)    phase_2_parsec ;;
        3_tailscale) phase_3_tailscale ;;
        4_vgl)       phase_4_vgl ;;
        5_minecraft) phase_5_minecraft ;;
        *)
            echo ""
            echo -e "  ${CYAN}Dùng:${NC} $0 [LỆNH]"
            echo ""
            echo -e "  ${YELLOW}all${NC}          — Cài toàn bộ"
            echo -e "  ${YELLOW}1_base${NC}       — Xvfb + Xfce + noVNC"
            echo -e "  ${YELLOW}2_parsec${NC}     — Parsec daemon"
            echo -e "  ${YELLOW}3_tailscale${NC}  — Tailscale VPN"
            echo -e "  ${YELLOW}4_vgl${NC}        — VirtualGL GPU"
            echo -e "  ${YELLOW}5_minecraft${NC}  — Java + Minecraft"
            echo ""
            exit 1
            ;;
    esac

    [ "$PHASE" != "all" ] && [ "$PHASE" != "1_base" ] && \
    [ "$PHASE" != "2_parsec" ] || true

    sep
    echo ""
    log "══ HOÀN TẤT ══"
    echo ""
    echo -e "  ${CYAN}Bước tiếp theo:${NC}"
    echo ""
    echo -e "  1. Mở ${YELLOW}Parsec app${NC} trên PC/điện thoại"
    echo -e "     → Máy ${YELLOW}'KaggleGPU'${NC} sẽ hiện trong danh sách"
    echo -e "     → Nhấn Connect"
    echo ""
    echo -e "  2. Chạy Minecraft:"
    echo -e "     ${YELLOW}bash /opt/minecraft/run_minecraft_gpu.sh prism${NC}"
    echo ""
    echo -e "  Xem trạng thái: ${YELLOW}gpu-desktop-status${NC}"
    echo ""
}

main "$@"
