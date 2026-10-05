#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
    echo "[-] Запустіть через sudo: sudo ./install.sh"
    exit 1
fi

echo "[+] Очищення старої BUDDY..."
systemctl stop wifi-failover.service 2>/dev/null || true
systemctl disable wifi-failover.service 2>/dev/null || true
rm -f /etc/systemd/system/wifi-failover.service
systemctl daemon-reload
rm -rf /opt/buddy

echo "[+] Встановлення залежностей..."
apt update
apt install -y python3 python3-flask network-manager iw curl

if ! command -v zerotier-cli >/dev/null 2>&1; then
    echo "[+] Встановлення ZeroTier..."
    curl -s https://install.zerotier.com | bash
fi

mkdir -p /opt/buddy
cd /opt/buddy

cat > /opt/buddy/app.py <<'PYEOF'
#!/usr/bin/env python3
import os
import re
import json
import shlex
import subprocess
import threading
import time
import urllib.parse
import urllib.request
import logging
from logging.handlers import RotatingFileHandler
from functools import wraps
from flask import Flask, Response, jsonify, render_template_string, request

CONFIG_FILE = "/opt/buddy/config.json"

DEFAULT_CONFIG = {
    "admin_user": os.getenv("BUDDY_USER", "admin"),
    "admin_pass": os.getenv("BUDDY_PASS", "admin"),
    "telegram_token": os.getenv("BUDDY_TELEGRAM_TOKEN", ""),
    "telegram_chat_id": os.getenv("BUDDY_TELEGRAM_CHAT_ID", ""),
    "zerotier_net": ""
}

def load_config():
    config = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
            for k, v in DEFAULT_CONFIG.items():
                config[k] = data.get(k, v)
        except Exception:
            pass
    return config

config = load_config()

log_formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
file_handler = RotatingFileHandler(
    "/opt/buddy/buddy.log",
    maxBytes=2 * 1024 * 1024,
    backupCount=3
)
file_handler.setFormatter(log_formatter)
console_handler = logging.StreamHandler()
console_handler.setFormatter(log_formatter)
logging.basicConfig(level=logging.INFO, handlers=[file_handler, console_handler])

app = Flask(__name__)

LAN_IFACE = "eth0"
WLAN_IFACE = "wlan0"
CHECK_INTERVAL = 3
MAX_TELEGRAM_QUEUE_SIZE = 50

state_lock = threading.Lock()
queue_lock = threading.Lock()

telegram_queue = []

lan_has_internet = False
wifi_has_internet = False
wifi_signal_strength = "Не підключено"
active_channel = "unknown"
failover_in_progress = False

# Prevent repeated event notifications.
last_event = None


def run_cmd(cmd, timeout=20):
    try:
        if isinstance(cmd, str):
            cmd = shlex.split(cmd)
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return result.stdout.strip()
    except Exception as e:
        logging.error("Помилка команди %s: %s", cmd, e)
        return ""


def check_auth(username, password):
    return (
        username == config["admin_user"]
        and password == config["admin_pass"]
    )


def authenticate():
    return Response(
        "Вхід заборонено.\n",
        401,
        {"WWW-Authenticate": 'Basic realm="BUDDY"'}
    )


def requires_auth(func):
    @wraps(func)
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return authenticate()
        return func(*args, **kwargs)
    return decorated


def send_telegram_message(message, force=False):
    if not config.get("telegram_token") or not config.get("telegram_chat_id"):
        logging.info("Telegram не налаштований: %s", message)
        return

    with queue_lock:
        if len(telegram_queue) >= MAX_TELEGRAM_QUEUE_SIZE:
            telegram_queue.pop(0)
        telegram_queue.append(message)

    logging.info("Telegram: %s", message)
    flush_telegram_queue()


def flush_telegram_queue():
    if not telegram_queue:
        return

    with queue_lock:
        messages = list(telegram_queue)

    for msg in messages:
        try:
            url = (
                f"https://api.telegram.org/bot"
                f"{config['telegram_token']}/sendMessage"
            )
            data = urllib.parse.urlencode({
                "chat_id": config["telegram_chat_id"],
                "text": msg
            }).encode("utf-8")

            urllib.request.urlopen(url, data=data, timeout=5)

            with queue_lock:
                if msg in telegram_queue:
                    telegram_queue.remove(msg)

        except Exception as e:
            logging.warning("Помилка Telegram: %s", e)
            break


def get_zerotier_node_id():
    out = run_cmd(["zerotier-cli", "info"], timeout=5)
    parts = out.split()
    if len(parts) >= 3:
        return parts[2]
    return "Не запущено / Невідомо"


def check_internet(interface, pings=1, timeout=1):
    """
    Перевірка Internet саме через заданий інтерфейс.
    ВАЖЛИВО: функція нічого не відключає і не змінює.
    """
    for ip in ("8.8.8.8", "1.1.1.1"):
        try:
            result = subprocess.run(
                [
                    "ping",
                    "-c", str(pings),
                    "-W", str(timeout),
                    "-I", interface,
                    ip
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=timeout * pings + 2
            )
            if result.returncode == 0:
                return True
        except Exception:
            pass

    return False


def get_wifi_signal():
    out = run_cmd([
        "nmcli", "-t",
        "-f", "IN-USE,SSID,SIGNAL",
        "device", "wifi", "list"
    ], timeout=5)

    for line in out.splitlines():
        parts = re.split(r"(?<!\\):", line)
        if len(parts) >= 3 and parts[0] == "*":
            ssid = parts[1].replace("\\:", ":")
            signal = parts[2]
            return f"{ssid} ({signal}%)"

    return "Не підключено"


def scan_all_wifi_networks():
    run_cmd(["nmcli", "dev", "wifi", "rescan"], timeout=10)

    out = run_cmd([
        "nmcli", "-t",
        "-f", "IN-USE,SSID,SIGNAL,BARS,SECURITY",
        "device", "wifi", "list"
    ], timeout=10)

    networks = []
    seen = set()

    for line in out.splitlines():
        parts = re.split(r"(?<!\\):", line)

        if len(parts) >= 5:
            in_use = parts[0] == "*"
            ssid = parts[1].replace("\\:", ":")
            signal = parts[2]
            bars = parts[3]
            security = parts[4]

            if ssid and ssid not in seen:
                seen.add(ssid)
                networks.append({
                    "in_use": in_use,
                    "ssid": ssid,
                    "signal": signal,
                    "bars": bars,
                    "security": security
                })

    return networks


def is_wifi_connected(signal_text):
    return (
        signal_text
        and signal_text != "Не підключено"
        and signal_text != "Немає підключення"
    )


def connect_open_wifi(ssid):
    """
    Підключає wlan0 до відкритої Wi-Fi.
    НІ eth0, НІ wlan0 тут не відключаються.
    """
    logging.info("Спроба підключення до відкритого Wi-Fi: %s", ssid)

    result = run_cmd([
        "nmcli",
        "device",
        "wifi",
        "connect",
        ssid,
        "ifname",
        WLAN_IFACE
    ], timeout=15)

    # Навіть якщо nmcli повернув порожній stdout, даємо час DHCP.
    for _ in range(5):
        if check_internet(WLAN_IFACE, pings=1, timeout=1):
            return True, result
        time.sleep(1)

    return False, result


def auto_failover_routine():
    global failover_in_progress

    with state_lock:
        if failover_in_progress:
            return "Already in progress"
        failover_in_progress = True

    try:
        send_telegram_message(
            "⚠️ Starlink/LAN недоступний. "
            "Перевіряю резервний Wi-Fi..."
        )

        # КРИТИЧНО:
        # Тут НЕМАЄ:
        # nmcli device disconnect eth0
        # nmcli device disconnect wlan0

        # Якщо wlan0 уже має Internet — нічого не робимо.
        if check_internet(WLAN_IFACE):
            return "Wi-Fi already active"

        networks = scan_all_wifi_networks()

        open_networks = []
        for net in networks:
            security = net["security"]
            is_open = (
                not security
                or security == "--"
                or security == ""
            )

            if net["ssid"] and is_open:
                open_networks.append(net)

        try:
            open_networks.sort(
                key=lambda x: int(x["signal"]),
                reverse=True
            )
        except Exception:
            pass

        if not open_networks:
            send_telegram_message(
                "❌ Не знайдено жодної відкритої Wi-Fi мережі."
            )
            return "No open networks"

        for net in open_networks:
            ssid = net["ssid"]
            signal = net["signal"]

            send_telegram_message(
                f"🔄 Спроба резервного Wi-Fi: "
                f"{ssid} ({signal}%)"
            )

            ok, result = connect_open_wifi(ssid)

            if ok:
                send_telegram_message(
                    f"✅ Резервний Wi-Fi працює.\n"
                    f"SSID: {ssid}\n"
                    f"Сигнал: {signal}%"
                )
                return f"Connected: {ssid}"

            logging.warning(
                "Wi-Fi %s не дав Internet: %s",
                ssid,
                result
            )

        send_telegram_message(
            "❌ Не вдалося отримати Internet "
            "через жодну відкриту Wi-Fi мережу."
        )
        return "Failed"

    finally:
        with state_lock:
            failover_in_progress = False


def set_event(event):
    global last_event

    with state_lock:
        if event == last_event:
            return False
        last_event = event
        return True


def network_monitor_worker():
    global lan_has_internet
    global wifi_has_internet
    global wifi_signal_strength
    global active_channel

    logging.info("BUDDY network monitor started")

    if set_event("startup"):
        send_telegram_message(
            "🚀 BUDDY Wi-Fi Failover запущено."
        )

    while True:
        try:
            lan_ok = check_internet(
                LAN_IFACE,
                pings=1,
                timeout=1
            )

            wlan_ok = check_internet(
                WLAN_IFACE,
                pings=1,
                timeout=1
            )

            signal = get_wifi_signal()

            with state_lock:
                old_lan = lan_has_internet
                old_wifi = wifi_has_internet

                lan_has_internet = lan_ok
                wifi_has_internet = wlan_ok
                wifi_signal_strength = signal

            # -------------------------------------------------
            # 1. STARLINK / LAN ПРАЦЮЄ
            # -------------------------------------------------
            if lan_ok:
                with state_lock:
                    active_channel = "LAN / STARLINK"

                # Якщо Starlink щойно відновився після відмови.
                if not old_lan:
                    if set_event("starlink_restored"):
                        send_telegram_message(
                            "✅ Starlink відновлено.\n"
                            "Основний канал знову доступний."
                        )

                # Якщо Wi-Fi також працює — НЕ відключаємо його.
                # Нічого не робимо.

            # -------------------------------------------------
            # 2. STARLINK НЕ ПРАЦЮЄ, WI-FI ПРАЦЮЄ
            # -------------------------------------------------
            elif wlan_ok:
                with state_lock:
                    active_channel = "Wi-Fi резерв"

                if old_lan:
                    if set_event("starlink_lost_wifi_active"):
                        send_telegram_message(
                            "⚠️ Starlink недоступний.\n"
                            "Працюю через резервний Wi-Fi."
                        )

            # -------------------------------------------------
            # 3. ОБИДВА КАНАЛИ НЕ ПРАЦЮЮТЬ
            # -------------------------------------------------
            else:
                with state_lock:
                    active_channel = "OFFLINE"

                if old_lan or old_wifi:
                    if set_event("both_down"):
                        send_telegram_message(
                            "🚨 КРИТИЧНО: Starlink і Wi-Fi "
                            "недоступні. Запускаю пошук резервної мережі."
                        )

                auto_failover_routine()

            # Якщо Starlink повернувся, але був доступний
            # через Wi-Fi — не перемикаємо і не відключаємо Wi-Fi.
            # Просто повідомляємо про відновлення Starlink.

            flush_telegram_queue()

        except Exception as e:
            logging.exception("Помилка network monitor: %s", e)

        time.sleep(CHECK_INTERVAL)


HTML_TEMPLATE = r"""
<!DOCTYPE html>
<html lang="uk">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>BUDDY - Network Failover</title>
<style>
body {
    font-family: Arial, sans-serif;
    background:#0f172a;
    color:#f8fafc;
    margin:0;
    padding:20px;
}
.container {
    max-width:900px;
    margin:auto;
}
.card {
    background:#1e293b;
    padding:20px;
    border-radius:8px;
    margin-bottom:20px;
}
h2 {
    margin-top:0;
    border-bottom:1px solid #334155;
    padding-bottom:10px;
}
.status {
    display:inline-block;
    padding:5px 12px;
    border-radius:5px;
    font-weight:bold;
}
.ok { background:#166534; color:#86efac; }
.bad { background:#991b1b; color:#fca5a5; }
.info { background:#075985; color:#bae6fd; }
button {
    border:0;
    padding:9px 14px;
    border-radius:5px;
    cursor:pointer;
    margin:4px;
    color:white;
    background:#0284c7;
}
.danger { background:#dc2626; }
.success { background:#16a34a; }
pre {
    background:#020617;
    padding:14px;
    border-radius:6px;
    overflow:auto;
}
table {
    width:100%;
    border-collapse:collapse;
}
th, td {
    padding:8px;
    border-bottom:1px solid #334155;
    text-align:left;
}
input {
    background:#0f172a;
    color:white;
    border:1px solid #475569;
    padding:8px;
    border-radius:4px;
    width:100%;
    box-sizing:border-box;
}
</style>
</head>
<body>
<div class="container">

<div class="card">
<h2>🚀 BUDDY Network Failover</h2>

<p>
<b>Активний канал:</b>
<span id="active" class="status info">...</span>
</p>

<p>
<b>Starlink / LAN:</b>
<span id="lan" class="status info">...</span>
</p>

<p>
<b>Wi-Fi:</b>
<span id="wifi" class="status info">...</span>
</p>

<p>
<b>Поточний Wi-Fi:</b>
<span id="signal" class="status info">...</span>
</p>

<p><b>Інтерфейси:</b></p>
<pre id="ips">...</pre>

<button onclick="control('restart')">Перезапустити BUDDY</button>
<button class="success" onclick="forceScan()">Сканувати Wi-Fi</button>
</div>

<div class="card">
<h2>⚙️ Налаштування</h2>

<label>ZeroTier Network ID</label>
<input id="zt-net">

<label>Telegram Bot Token</label>
<input id="tg-token" type="password">

<label>Telegram Chat ID</label>
<input id="tg-chat">

<label>Логін</label>
<input id="user">

<label>Пароль</label>
<input id="pass" type="password">

<button class="success" onclick="saveConfig()">Зберегти</button>
<p id="config-result"></p>

<p><b>ZeroTier Node ID:</b></p>
<pre id="zt-id">...</pre>
</div>

<div class="card">
<h2>📡 Wi-Fi мережі</h2>
<button onclick="scanWifi()">Оновити</button>
<div id="wifi-list">...</div>
</div>

<div class="card">
<h2>📋 Логи</h2>
<button onclick="loadLogs()">Оновити</button>
<pre id="logs">...</pre>
</div>

</div>

<script>
async function updateStatus() {
    try {
        const r = await fetch('/api/status');
        const d = await r.json();

        document.getElementById('active').innerText =
            d.active_channel;

        document.getElementById('lan').innerText =
            d.lan_internet ? 'ПРАЦЮЄ' : 'НЕМАЄ';

        document.getElementById('wifi').innerText =
            d.wifi_internet ? 'ПРАЦЮЄ' : 'НЕМАЄ';

        document.getElementById('signal').innerText =
            d.wifi_signal;

        document.getElementById('ips').innerText =
            d.ips;
    } catch(e) {}
}

async function loadConfig() {
    try {
        const r = await fetch('/api/config');
        const d = await r.json();

        document.getElementById('zt-net').value =
            d.zerotier_net || '';

        document.getElementById('tg-token').value =
            d.telegram_token || '';

        document.getElementById('tg-chat').value =
            d.telegram_chat_id || '';

        document.getElementById('user').value =
            d.admin_user || '';

        document.getElementById('pass').value =
            d.admin_pass || '';

        document.getElementById('zt-id').innerText =
            d.zerotier_node_id || 'Не визначено';
    } catch(e) {}
}

async function saveConfig() {
    const payload = {
        zerotier_net:
            document.getElementById('zt-net').value,
        telegram_token:
            document.getElementById('tg-token').value,
        telegram_chat_id:
            document.getElementById('tg-chat').value,
        admin_user:
            document.getElementById('user').value,
        admin_pass:
            document.getElementById('pass').value
    };

    const r = await fetch('/api/config', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body:JSON.stringify(payload)
    });

    const d = await r.json();
    document.getElementById('config-result').innerText =
        d.message;
}

async function scanWifi() {
    const box = document.getElementById('wifi-list');
    box.innerText = 'Сканування...';

    try {
        const r = await fetch('/api/scan');
        const d = await r.json();

        if (!d.networks.length) {
            box.innerText = 'Мереж не знайдено.';
            return;
        }

        let html = '<table>';
        html += '<tr><th>SSID</th><th>Сигнал</th><th>Захист</th><th>Статус</th></tr>';

        for (const n of d.networks) {
            html += '<tr>';
            html += '<td><b>' + n.ssid + '</b></td>';
            html += '<td>' + n.signal + '%</td>';
            html += '<td>' + (n.security || 'Відкрита') + '</td>';
            html += '<td>' + (n.in_use ? '🟢' : '') + '</td>';
            html += '</tr>';
        }

        html += '</table>';
        box.innerHTML = html;
    } catch(e) {
        box.innerText = 'Помилка сканування.';
    }
}

async function forceScan() {
    await scanWifi();
}

async function loadLogs() {
    try {
        const r = await fetch('/api/logs');
        const d = await r.json();
        document.getElementById('logs').innerText =
            d.logs || 'Немає записів.';
    } catch(e) {}
}

async function control(action) {
    await fetch('/api/control/' + action, {
        method:'POST'
    });
    setTimeout(updateStatus, 1000);
}

loadConfig();
updateStatus();
scanWifi();
loadLogs();

setInterval(updateStatus, 3000);
setInterval(loadLogs, 10000);
</script>
</body>
</html>
"""


@app.route("/")
@requires_auth
def index():
    return render_template_string(HTML_TEMPLATE)


@app.route("/api/status")
@requires_auth
def api_status():
    with state_lock:
        return jsonify({
            "lan_internet": lan_has_internet,
            "wifi_internet": wifi_has_internet,
            "wifi_signal": wifi_signal_strength,
            "active_channel": active_channel,
            "ips": run_cmd(["ip", "-4", "-br", "addr", "show"])
        })


@app.route("/api/config", methods=["GET", "POST"])
@requires_auth
def api_config():
    global config

    if request.method == "POST":
        data = request.json or {}

        config.update({
            "admin_user": data.get(
                "admin_user",
                config["admin_user"]
            ),
            "admin_pass": data.get(
                "admin_pass",
                config["admin_pass"]
            ),
            "telegram_token": data.get(
                "telegram_token",
                config["telegram_token"]
            ),
            "telegram_chat_id": data.get(
                "telegram_chat_id",
                config["telegram_chat_id"]
            ),
            "zerotier_net": data.get(
                "zerotier_net",
                config["zerotier_net"]
            )
        })

        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=4, ensure_ascii=False)

        zt_net = config["zerotier_net"].strip()
        if zt_net:
            run_cmd([
                "zerotier-cli",
                "join",
                zt_net
            ], timeout=10)

        return jsonify({
            "success": True,
            "message": "✅ Налаштування збережено."
        })

    result = dict(config)
    result["zerotier_node_id"] = get_zerotier_node_id()
    return jsonify(result)


@app.route("/api/scan")
@requires_auth
def api_scan():
    return jsonify({
        "networks": scan_all_wifi_networks()
    })


@app.route("/api/logs")
@requires_auth
def api_logs():
    logs = run_cmd([
        "journalctl",
        "-u",
        "wifi-failover.service",
        "-n",
        "50",
        "--no-pager"
    ])
    return jsonify({"logs": logs})


@app.route("/api/control/<action>", methods=["POST"])
@requires_auth
def api_control(action):
    if action not in ("start", "stop", "restart"):
        return jsonify({
            "status": "invalid action"
        }), 400

    run_cmd([
        "systemctl",
        action,
        "wifi-failover.service"
    ])

    return jsonify({"status": "ok"})


@app.route("/api/connect", methods=["POST"])
@requires_auth
def api_connect():
    data = request.json or {}
    ssid = data.get("ssid")
    password = data.get("password", "")

    if not ssid:
        return jsonify({
            "message": "SSID не вказано"
        }), 400

    cmd = [
        "nmcli",
        "device",
        "wifi",
        "connect",
        ssid,
        "ifname",
        WLAN_IFACE
    ]

    if password:
        cmd.extend(["password", password])

    result = run_cmd(cmd, timeout=15)

    return jsonify({
        "message": result or "Запит виконано."
    })


if __name__ == "__main__":
    monitor_thread = threading.Thread(
        target=network_monitor_worker,
        daemon=True
    )
    monitor_thread.start()

    app.run(
        host="0.0.0.0",
        port=8081
    )
PYEOF

chmod +x /opt/buddy/app.py
touch /opt/buddy/buddy.log
chmod 640 /opt/buddy/buddy.log

cat > /etc/systemd/system/wifi-failover.service <<'EOF'
[Unit]
Description=BUDDY Wi-Fi Failover Service
After=network.target NetworkManager.service zerotier-one.service
Wants=NetworkManager.service

[Service]
Type=simple
User=root
WorkingDirectory=/opt/buddy
ExecStart=/usr/bin/python3 /opt/buddy/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wifi-failover.service
systemctl restart wifi-failover.service

sleep 2

LOCAL_IPS=$(hostname -I 2>/dev/null || true)
ZT_IPS=$(ip -4 -o addr show 2>/dev/null |
    grep -E 'zt|zt[a-zA-Z0-9]' |
    awk '{print $4}' |
    cut -d/ -f1 || true)

echo
echo "======================================================"
echo "[+] BUDDY успішно встановлено"
echo
echo "[+] ВАЖЛИВО:"
echo "    eth0  = основний Starlink"
echo "    wlan0 = резервний Wi-Fi"
echo
echo "[+] BUDDY НЕ робить автоматично:"
echo "    nmcli device disconnect eth0"
echo "    nmcli device disconnect wlan0"
echo
echo "[+] Starlink повертається в контроль автоматично,"
echo "    але Wi-Fi при цьому НЕ відключається."
echo
echo "[+] Вебпанель:"
for ip in $LOCAL_IPS; do
    echo "    http://$ip:8081"
done

if [ -n "$ZT_IPS" ]; then
    echo
    echo "[+] ZeroTier:"
    for ip in $ZT_IPS; do
        echo "    http://$ip:8081"
    done
fi

echo
echo "[+] Логін: admin"
echo "[+] Пароль: admin"
echo
echo "[+] Telegram Token і Chat ID задаються"
echo "    через вебпанель після встановлення."
echo
echo "======================================================"
echo "[+] Перевірка служби:"
systemctl --no-pager --full status wifi-failover.service || true
echo "======================================================"
