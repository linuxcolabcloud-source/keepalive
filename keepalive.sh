#!/bin/bash
# =============================================================================
# KEEPALIVE SCRIPT — Chống ngắt kết nối Colab/Kaggle
# Bao gồm: JS keepalive, watchdog tự restart service, GPU activity giả
# =============================================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
sep()  { echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }

# ─── Phát hiện môi trường ────────────────────────────────────────────────────
detect_env() {
    if [ -d /content ]; then
        echo "colab"
    elif [ -d /kaggle ]; then
        echo "kaggle"
    else
        echo "other"
    fi
}
ENV_TYPE=$(detect_env)

# ─── File PID tracking ───────────────────────────────────────────────────────
KEEPALIVE_DIR="/tmp/keepalive"
mkdir -p "$KEEPALIVE_DIR"
PID_FILE="$KEEPALIVE_DIR/pids"
LOG_FILE="$KEEPALIVE_DIR/keepalive.log"
> "$PID_FILE"

log_ka() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# ═══════════════════════════════════════════════════════════════════════════════
# 1. JAVASCRIPT KEEPALIVE (click nút Colab / Kaggle tự động)
#    — Chạy phía browser, paste vào Console tab của browser
# ═══════════════════════════════════════════════════════════════════════════════
generate_js_keepalive() {
    sep
    info "Tạo JS Keepalive cho Browser Console..."

    cat > /tmp/keepalive_browser.js <<'JSEOF'
// ══════════════════════════════════════════════════════
// PASTE VÀO BROWSER CONSOLE (F12 → Console)
// Chạy 1 lần — tự động giữ session sống
// ══════════════════════════════════════════════════════
(function keepAlive() {
    const INTERVAL_MS = 10 * 1000; // 10 giây

    function clickKeepAlive() {
        const now = new Date().toLocaleTimeString();

        // Google Colab: click nút connect / run cell
        const colabSelectors = [
            'colab-connect-button',
            'colab-toolbar-button[icon="settings"]',
            '#connect',
        ];
        for (const sel of colabSelectors) {
            const el = document.querySelector(sel);
            if (el) { el.click(); console.log(`[${now}] Colab keepalive ✓`); return; }
        }

        // Kaggle: di chuyển chuột giả để tránh idle
        document.dispatchEvent(new MouseEvent('mousemove', {
            bubbles: true, cancelable: true,
            clientX: Math.random() * window.innerWidth,
            clientY: Math.random() * window.innerHeight,
        }));

        // Scroll nhỏ để tránh browser throttle
        window.scrollBy(0, 1);
        window.scrollBy(0, -1);

        console.log(`[${now}] Keepalive ping ✓`);
    }

    // Chạy ngay lần đầu
    clickKeepAlive();
    // Lặp lại
    const timer = setInterval(clickKeepAlive, INTERVAL_MS);

    // Lưu để có thể dừng: clearInterval(window._keepAliveTimer)
    window._keepAliveTimer = timer;
    console.log('✅ Keepalive đã bật — dừng bằng: clearInterval(window._keepAliveTimer)');
})();
JSEOF

    log "File JS: /tmp/keepalive_browser.js"
    sep
    warn "▶ PASTE đoạn sau vào Browser Console (F12):"
    echo ""
    cat /tmp/keepalive_browser.js
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# 2. PYTHON KEEPALIVE CELL (dùng trong notebook cell)
# ═══════════════════════════════════════════════════════════════════════════════
generate_python_keepalive() {
    sep
    info "Tạo Python Keepalive cell..."

    cat > /tmp/keepalive_cell.py <<'PYEOF'
# ══════════════════════════════════════════════════════
# CELL NÀY GIỮ COLAB/KAGGLE KHÔNG BỊ TIMEOUT
# Chạy ở cell riêng, song song với cell khác
# ══════════════════════════════════════════════════════
import time, threading, subprocess, os, sys
from datetime import datetime

PING_INTERVAL = 10   # giây
GPU_ACTIVITY  = True # giả lập GPU để Colab không idle

def ping_loop():
    i = 0
    while True:
        ts = datetime.now().strftime("%H:%M:%S")
        # Giữ CPU khỏi idle
        _ = sum(range(10_000))

        # Giả lập GPU activity nhẹ (không ăn nhiều VRAM)
        if GPU_ACTIVITY:
            try:
                import torch
                if torch.cuda.is_available():
                    x = torch.zeros(1, device='cuda')
                    del x
                    torch.cuda.empty_cache()
            except ImportError:
                pass

        i += 1
        print(f"\r[{ts}] Keepalive #{i} ✓  (Ctrl+C để dừng)", end="", flush=True)
        time.sleep(PING_INTERVAL)

# Chạy background thread để không block cell khác
t = threading.Thread(target=ping_loop, daemon=True)
t.start()
print("✅ Keepalive thread đã chạy ngầm")
PYEOF

    log "Python cell: /tmp/keepalive_cell.py"
    info "Copy nội dung file trên vào 1 cell notebook và chạy"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3. WATCHDOG — Tự động restart service nếu bị crash
# ═══════════════════════════════════════════════════════════════════════════════
start_watchdog() {
    sep
    info "Khởi động Watchdog (tự restart Xvfb/Sunshine/Tailscale)..."

    cat > "$KEEPALIVE_DIR/watchdog.sh" <<'WDEOF'
#!/bin/bash
LOG="/tmp/keepalive/watchdog.log"
log_wd() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

restart_xvfb() {
    pkill -f "Xvfb :99" 2>/dev/null || true; sleep 1
    Xvfb :99 -screen 0 1920x1080x24 -ac +extension GLX +render -noreset &
    sleep 2
    DISPLAY=:99 startxfce4 &>/tmp/xfce4.log &
    sleep 2
    x11vnc -display :99 -nopw -forever -shared -bg -o /tmp/x11vnc.log 2>/dev/null || true
    websockify --web=/usr/share/novnc/ 6080 localhost:5900 &>/dev/null 2>&1 &
    log_wd "Xvfb + Xfce đã restart"
}

restart_sunshine() {
    pkill -x sunshine 2>/dev/null || true; sleep 1
    DISPLAY=:99 nohup sunshine \
        /root/.config/sunshine/sunshine.conf &>/tmp/sunshine.log &
    log_wd "Sunshine đã restart"
}

check_tailscale() {
    if ! tailscale status &>/dev/null; then
        log_wd "Tailscale mất kết nối — thử reconnect..."
        tailscale up --accept-routes 2>/dev/null || true
    fi
}

log_wd "Watchdog khởi động"
while true; do
    # Kiểm tra Xvfb
    if ! pgrep -x Xvfb &>/dev/null; then
        log_wd "⚠ Xvfb chết — restart..."
        restart_xvfb
    fi

    # Kiểm tra Sunshine
    if ! pgrep -x sunshine &>/dev/null; then
        log_wd "⚠ Sunshine chết — restart..."
        restart_sunshine
    fi

    # Kiểm tra Tailscale mỗi 5 phút
    if [ $(( $(date +%s) % 300 )) -lt 30 ]; then
        check_tailscale
    fi

    sleep 30
done
WDEOF
    chmod +x "$KEEPALIVE_DIR/watchdog.sh"
    nohup bash "$KEEPALIVE_DIR/watchdog.sh" &>/dev/null &
    echo $! >> "$PID_FILE"
    log "Watchdog PID: $! (restart check mỗi 30 giây)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4. FAKE GPU ACTIVITY — Ngăn Colab thu hồi GPU khi idle
# ═══════════════════════════════════════════════════════════════════════════════
start_gpu_keepalive() {
    sep
    info "Khởi động GPU Keepalive (ngăn Colab thu hồi GPU idle)..."

    cat > "$KEEPALIVE_DIR/gpu_ping.py" <<'GPUEOF'
#!/usr/bin/env python3
"""
Chạy phép tính nhỏ trên GPU mỗi 2 phút
Đủ để Colab nghĩ GPU đang được dùng, không thu hồi
"""
import time, sys
from datetime import datetime

try:
    import torch
    HAS_TORCH = torch.cuda.is_available()
except ImportError:
    HAS_TORCH = False

try:
    import subprocess
    HAS_NVIDIA = subprocess.run(['nvidia-smi'], capture_output=True).returncode == 0
except:
    HAS_NVIDIA = False

def gpu_ping():
    if HAS_TORCH:
        # Ma trận nhỏ — dùng ~10MB VRAM, xong xóa ngay
        a = torch.rand(512, 512, device='cuda')
        b = torch.rand(512, 512, device='cuda')
        _ = torch.mm(a, b)
        del a, b, _
        torch.cuda.empty_cache()
        return "CUDA matmul"
    elif HAS_NVIDIA:
        import subprocess
        subprocess.run(['nvidia-smi', '--query-gpu=utilization.gpu',
                       '--format=csv,noheader'], capture_output=True)
        return "nvidia-smi query"
    else:
        return "CPU only (no GPU found)"

INTERVAL = 120  # 2 phút
print(f"GPU Keepalive started (ping mỗi {INTERVAL}s)")
i = 0
while True:
    try:
        method = gpu_ping()
        ts = datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] GPU ping #{i} — {method}", flush=True)
        i += 1
    except Exception as e:
        print(f"GPU ping error: {e}", flush=True)
    time.sleep(INTERVAL)
GPUEOF

    nohup python3 "$KEEPALIVE_DIR/gpu_ping.py" >> "$LOG_FILE" 2>&1 &
    echo $! >> "$PID_FILE"
    log "GPU Keepalive PID: $!"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5. HEARTBEAT LOG — In timestamp mỗi phút (giữ output cell sống)
# ═══════════════════════════════════════════════════════════════════════════════
start_heartbeat() {
    sep
    info "Khởi động Heartbeat logger..."

    cat > "$KEEPALIVE_DIR/heartbeat.sh" <<'HBEOF'
#!/bin/bash
i=0
while true; do
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    ts_alive=$(date -d "@$SECONDS" -u '+%Hh%Mm' 2>/dev/null || echo "${SECONDS}s")
    echo "[${ts}] ♥ Heartbeat #$((++i)) — uptime ${ts_alive}"
    # Giữ disk activity (tránh bị đánh giá idle)
    echo "$ts" > /tmp/keepalive/last_beat
    sleep 60
done
HBEOF
    chmod +x "$KEEPALIVE_DIR/heartbeat.sh"
    nohup bash "$KEEPALIVE_DIR/heartbeat.sh" >> "$LOG_FILE" 2>&1 &
    echo $! >> "$PID_FILE"
    log "Heartbeat PID: $!"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STOP — Dừng tất cả
# ═══════════════════════════════════════════════════════════════════════════════
stop_all() {
    sep
    info "Dừng tất cả keepalive processes..."
    if [ -f "$PID_FILE" ]; then
        while read -r pid; do
            kill "$pid" 2>/dev/null && log "Đã dừng PID $pid" || true
        done < "$PID_FILE"
        > "$PID_FILE"
    fi
    pkill -f "gpu_ping.py" 2>/dev/null || true
    pkill -f "watchdog.sh" 2>/dev/null || true
    pkill -f "heartbeat.sh" 2>/dev/null || true
    log "Tất cả keepalive đã dừng"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STATUS
# ═══════════════════════════════════════════════════════════════════════════════
show_status() {
    sep
    echo -e "${CYAN}══ Keepalive Status ══${NC}"
    echo "Watchdog:    $(pgrep -f watchdog.sh   &>/dev/null && echo '✅ RUNNING' || echo '❌ STOPPED')"
    echo "GPU Ping:    $(pgrep -f gpu_ping.py   &>/dev/null && echo '✅ RUNNING' || echo '❌ STOPPED')"
    echo "Heartbeat:   $(pgrep -f heartbeat.sh  &>/dev/null && echo '✅ RUNNING' || echo '❌ STOPPED')"
    echo ""
    echo "Log: tail -f $LOG_FILE"
    echo ""
    echo "Dòng log cuối:"
    tail -5 "$LOG_FILE" 2>/dev/null || echo "(chưa có log)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════════
main() {
    CMD="${1:-start}"
    case "$CMD" in
        start)
            sep
            log "Khởi động tất cả keepalive ($ENV_TYPE)..."
            start_watchdog
            start_gpu_keepalive
            start_heartbeat
            generate_js_keepalive
            generate_python_keepalive
            sep
            log "✅ Keepalive đã chạy đầy đủ"
            info "Xem log: tail -f $LOG_FILE"
            info "Dừng:    bash $0 stop"
            info "Status:  bash $0 status"
            echo ""
            warn "QUAN TRỌNG: Còn cần paste JS vào Browser Console"
            warn "File JS đã lưu tại: /tmp/keepalive_browser.js"
            ;;
        stop)    stop_all ;;
        status)  show_status ;;
        js)      generate_js_keepalive ;;
        python)  generate_python_keepalive ;;
        *)
            echo "Dùng: $0 [start|stop|status|js|python]"
            exit 1
            ;;
    esac
}

main "$@"
