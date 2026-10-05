#!/bin/bash
set -Eeuo pipefail

if [ "$EUID" -ne 0 ]; then
    echo "[-] Запустіть через sudo: sudo ./install.sh"
    exit 1
fi

if [ ! -r /etc/os-release ]; then
    echo "[-] Не вдалося визначити Linux-дистрибутив."
    exit 1
fi
ID=""
ID_LIKE=""
. /etc/os-release
case " $ID $ID_LIKE " in
    *debian*|*raspbian*) ;;
    *)
        echo "[-] Підтримується Raspberry Pi OS / Debian."
        exit 1
        ;;
esac
if ! command -v systemctl >/dev/null 2>&1; then
    echo "[-] Потрібна система з systemd."
    exit 1
fi

echo "[+] Підготовка оновлення BUDDY (конфігурація зберігається)..."
mkdir -p /opt/buddy

echo "[+] Встановлення залежностей..."
apt-get update
apt-get install -y python3 python3-flask python3-waitress network-manager iw curl ca-certificates iputils-ping git meson ninja-build pkg-config gcc g++ libsystemd-dev

INSTALL_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$INSTALL_TMP_DIR"' EXIT

if ! command -v zerotier-cli >/dev/null 2>&1; then
    echo "[+] Встановлення ZeroTier..."
    curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
        https://install.zerotier.com -o "$INSTALL_TMP_DIR/zerotier-install.sh"
    bash "$INSTALL_TMP_DIR/zerotier-install.sh"
fi

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
from waitress import serve

CONFIG_FILE = os.getenv("BUDDY_CONFIG_FILE", "/opt/buddy/config.json")
LOG_FILE = os.getenv("BUDDY_LOG_FILE", "/opt/buddy/buddy.log")

DEFAULT_CONFIG = {
    "admin_user": os.getenv("BUDDY_USER", ""),
    "admin_pass": os.getenv("BUDDY_PASS", ""),
    "telegram_token": os.getenv("BUDDY_TELEGRAM_TOKEN", ""),
    "telegram_chat_id": os.getenv("BUDDY_TELEGRAM_CHAT_ID", ""),
    "zerotier_net": ""
}

def load_config():
    config = dict(DEFAULT_CONFIG)
    if not os.path.exists(CONFIG_FILE):
        return config

    try:
        with open(CONFIG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as exc:
        raise RuntimeError(f"Invalid or unreadable config file: {CONFIG_FILE}") from exc

    if not isinstance(data, dict):
        raise RuntimeError(f"Config file must contain a JSON object: {CONFIG_FILE}")

    for key, default in DEFAULT_CONFIG.items():
        config[key] = data.get(key, default)
    return config

config = load_config()
if not config.get("admin_user") or not config.get("admin_pass"):
    raise RuntimeError("Set a non-empty BUDDY admin username and password in config.json before starting.")

os.umask(0o027)
log_formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
file_handler = RotatingFileHandler(
    LOG_FILE,
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
LAN_ROUTE_METRIC = 100
WIFI_ROUTE_METRIC = 600
WIFI_FAILOVER_ROUTE_METRIC = 50

state_lock = threading.Lock()
queue_lock = threading.Lock()

telegram_queue = []

lan_has_internet = False
wifi_has_internet = False
wifi_signal_strength = "Не підключено"
active_channel = "unknown"
failover_in_progress = False

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
    return (username == config["admin_user"] and password == config["admin_pass"])

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

    logging.info("Додано в чергу Telegram: %s", message)

def telegram_worker():
    """Фоновий потік, який постійно перевіряє чергу і відправляє повідомлення."""
    logging.info("BUDDY Telegram worker started")
    
    while True:
        if not (lan_has_internet or wifi_has_internet) or not config.get("telegram_token"):
            time.sleep(2)
            continue

        msg = None
        with queue_lock:
            if telegram_queue:
                msg = telegram_queue[0]

        if msg:
            try:
                url = f"https://api.telegram.org/bot{config['telegram_token']}/sendMessage"
                data = urllib.parse.urlencode({
                    "chat_id": config["telegram_chat_id"],
                    "text": msg
                }).encode("utf-8")

                urllib.request.urlopen(url, data=data, timeout=5)

                with queue_lock:
                    if telegram_queue and telegram_queue[0] == msg:
                        telegram_queue.pop(0)
                        
            except Exception as e:
                logging.warning("Помилка API Telegram (повтор через 5с): %s", e)
                time.sleep(5) 
        else:
            time.sleep(1)

def get_zerotier_node_id():
    out = run_cmd(["zerotier-cli", "info"], timeout=5)
    parts = out.split()
    if len(parts) >= 3:
        return parts[2]
    return "Не запущено / Невідомо"

def check_internet(interface, pings=1, timeout=1):
    for ip in ("8.8.8.8", "1.1.1.1"):
        try:
            result = subprocess.run(
                ["ping", "-c", str(pings), "-W", str(timeout), "-I", interface, ip],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=timeout * pings + 2
            )
            if result.returncode == 0:
                return True
        except Exception:
            pass
    return False

def get_default_routes(interface):
    routes = run_cmd(["ip", "-4", "route", "show", "default", "dev", interface], timeout=5)
    parsed = []
    for route in routes.splitlines():
        parts = route.split()
        if not parts or parts[0] != "default":
            continue
        gateway = parts[parts.index("via") + 1] if "via" in parts and parts.index("via") + 1 < len(parts) else None
        try:
            metric = int(parts[parts.index("metric") + 1]) if "metric" in parts else 0
        except (ValueError, IndexError):
            logging.warning("Невідомий metric у default route: %s", route)
            continue
        if gateway:
            parsed.append({"gateway": gateway, "metric": metric})
    return parsed

def set_default_route_metric(interface, metric):
    routes = get_default_routes(interface)
    if not routes:
        return False

    # Keep the currently preferred gateway if NetworkManager has installed
    # duplicate routes for this interface, then remove stale metric variants.
    route = min(routes, key=lambda item: item["metric"])
    gateway = route["gateway"]
    try:
        result = subprocess.run(
            ["ip", "-4", "route", "replace", "default", "via", gateway,
             "dev", interface, "metric", str(metric)],
            capture_output=True,
            text=True,
            timeout=5
        )
        if result.returncode != 0:
            logging.warning("Не вдалося змінити metric default route для %s: %s",
                            interface, result.stderr.strip())
            return False

        cleanup_ok = True
        for old_route in routes:
            if old_route["gateway"] == gateway and old_route["metric"] == metric:
                continue
            delete_cmd = ["ip", "-4", "route", "del", "default", "via",
                          old_route["gateway"], "dev", interface, "metric",
                          str(old_route["metric"])]
            cleanup = subprocess.run(
                delete_cmd, capture_output=True, text=True, timeout=5
            )
            if cleanup.returncode != 0:
                cleanup_ok = False
                logging.warning("Не вдалося видалити застарілий default route %s: %s",
                                interface, cleanup.stderr.strip())
        return cleanup_ok
    except Exception:
        logging.exception("Помилка встановлення маршруту через %s", interface)
        return False

def apply_default_route_policy(lan_ok, wifi_ok):
    """Prefer Ethernet while it has Internet; prefer Wi-Fi during failover."""
    if lan_ok:
        set_default_route_metric(LAN_IFACE, LAN_ROUTE_METRIC)
        set_default_route_metric(WLAN_IFACE, WIFI_ROUTE_METRIC)
    elif wifi_ok:
        set_default_route_metric(WLAN_IFACE, WIFI_FAILOVER_ROUTE_METRIC)
        set_default_route_metric(LAN_IFACE, LAN_ROUTE_METRIC)

def get_wifi_signal():
    out = run_cmd(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL", "device", "wifi", "list"], timeout=5)
    for line in out.splitlines():
        parts = re.split(r"(?<!\\):", line)
        if len(parts) >= 3 and parts[0] == "*":
            ssid = parts[1].replace("\\:", ":")
            signal = parts[2]
            return f"{ssid} ({signal}%)"
    return "Не підключено"

def scan_all_wifi_networks():
    run_cmd(["nmcli", "dev", "wifi", "rescan"], timeout=10)
    out = run_cmd(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,BARS,SECURITY", "device", "wifi", "list"], timeout=10)
    
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

def connect_open_wifi(ssid):
    logging.info("Спроба підключення до відкритого Wi-Fi: %s", ssid)
    try:
        completed = subprocess.run(
            ["nmcli", "device", "wifi", "connect", ssid, "ifname", WLAN_IFACE],
            capture_output=True, text=True, timeout=15
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        logging.warning("Не вдалося запустити підключення до Wi-Fi %s: %s", ssid, exc)
        return False, str(exc)
    result = (completed.stderr or completed.stdout or "").strip()
    if completed.returncode != 0:
        return False, result
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
        send_telegram_message("⚠️ Starlink/LAN недоступний. Перевіряю резервний Wi-Fi...")

        if check_internet(WLAN_IFACE):
            return "Wi-Fi already active"

        networks = scan_all_wifi_networks()
        open_networks = []
        for net in networks:
            security = net["security"]
            is_open = (not security or security == "--" or security == "")
            if net["ssid"] and is_open:
                open_networks.append(net)

        try:
            open_networks.sort(key=lambda x: int(x["signal"]), reverse=True)
        except Exception:
            pass

        if not open_networks:
            send_telegram_message("❌ Не знайдено жодної відкритої Wi-Fi мережі.")
            return "No open networks"

        for net in open_networks:
            ssid = net["ssid"]
            signal = net["signal"]

            send_telegram_message(f"🔄 Спроба резервного Wi-Fi: {ssid} ({signal}%)")
            ok, result = connect_open_wifi(ssid)

            if ok:
                send_telegram_message(f"✅ Резервний Wi-Fi працює.\nSSID: {ssid}\nСигнал: {signal}%")
                return f"Connected: {ssid}"

            logging.warning("Wi-Fi %s не дав Internet: %s", ssid, result)
            # Примусово відключаємо мертву мережу, щоб не зависали маршрути
            run_cmd(["nmcli", "device", "disconnect", WLAN_IFACE])

        send_telegram_message("❌ Не вдалося отримати Internet через жодну відкриту Wi-Fi мережу.")
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
        send_telegram_message("🚀 BUDDY Wi-Fi Failover запущено.")

    while True:
        try:
            lan_ok = check_internet(LAN_IFACE, pings=1, timeout=1)
            wlan_ok = check_internet(WLAN_IFACE, pings=1, timeout=1)
            signal = get_wifi_signal()
            apply_default_route_policy(lan_ok, wlan_ok)

            with state_lock:
                old_lan = lan_has_internet
                old_wifi = wifi_has_internet
                lan_has_internet = lan_ok
                wifi_has_internet = wlan_ok
                wifi_signal_strength = signal

            if lan_ok:
                with state_lock:
                    active_channel = "LAN / STARLINK"
                if not old_lan:
                    if set_event("starlink_restored"):
                        send_telegram_message("✅ Starlink відновлено.\nОсновний канал знову доступний.")

            elif wlan_ok:
                with state_lock:
                    active_channel = "Wi-Fi резерв"
                if old_lan:
                    if set_event("starlink_lost_wifi_active"):
                        send_telegram_message("⚠️ Starlink недоступний.\nПрацюю через резервний Wi-Fi.")

            else:
                with state_lock:
                    active_channel = "OFFLINE"
                if old_lan or old_wifi:
                    if set_event("both_down"):
                        send_telegram_message("🚨 КРИТИЧНО: Starlink і Wi-Fi недоступні. Запускаю пошук резервної мережі.")
                
                # Запускаємо в окремому потоці, щоб не блокувати моніторинг Starlink
                if not failover_in_progress:
                    threading.Thread(target=auto_failover_routine, daemon=True).start()

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
body { font-family: Arial, sans-serif; background:#0f172a; color:#f8fafc; margin:0; padding:20px; }
.container { max-width:900px; margin:auto; }
.card { background:#1e293b; padding:20px; border-radius:8px; margin-bottom:20px; }
h2 { margin-top:0; border-bottom:1px solid #334155; padding-bottom:10px; }
.status { display:inline-block; padding:5px 12px; border-radius:5px; font-weight:bold; }
.ok { background:#166534; color:#86efac; }
.bad { background:#991b1b; color:#fca5a5; }
.info { background:#075985; color:#bae6fd; }
button { border:0; padding:9px 14px; border-radius:5px; cursor:pointer; margin:4px; color:white; background:#0284c7; }
.danger { background:#dc2626; }
.success { background:#16a34a; }
pre { background:#020617; padding:14px; border-radius:6px; overflow:auto; }
table { width:100%; border-collapse:collapse; }
th, td { padding:8px; border-bottom:1px solid #334155; text-align:left; }
input { background:#0f172a; color:white; border:1px solid #475569; padding:8px; border-radius:4px; width:100%; box-sizing:border-box; }
</style>
</head>
<body>
<div class="container">

<div class="card">
<h2>🚀 BUDDY Network Failover</h2>
<p><b>Активний канал:</b> <span id="active" class="status info">...</span></p>
<p><b>Starlink / LAN:</b> <span id="lan" class="status info">...</span></p>
<p><b>Wi-Fi:</b> <span id="wifi" class="status info">...</span></p>
<p><b>Поточний Wi-Fi:</b> <span id="signal" class="status info">...</span></p>
<p><b>Інтерфейси:</b></p>
<pre id="ips">...</pre>
<button onclick="control('restart')">Перезапустити BUDDY</button>
<button class="success" onclick="forceScan()">Сканувати Wi-Fi</button>
</div>

<div class="card">
<h2>⚙️ Налаштування</h2>
<label>ZeroTier Network ID</label><input id="zt-net">
<label>Telegram Bot Token</label><input id="tg-token" type="password">
<label>Telegram Chat ID</label><input id="tg-chat">
<label>Логін</label><input id="user">
<label>Пароль</label><input id="pass" type="password">
<button class="success" onclick="saveConfig()">Зберегти</button>
<p>Пароль адміністратора й Telegram token не показуються. Порожнє поле залишає поточне значення.</p>
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
        document.getElementById('active').innerText = d.active_channel;
        document.getElementById('lan').innerText = d.lan_internet ? 'ПРАЦЮЄ' : 'НЕМАЄ';
        document.getElementById('wifi').innerText = d.wifi_internet ? 'ПРАЦЮЄ' : 'НЕМАЄ';
        document.getElementById('signal').innerText = d.wifi_signal;
        document.getElementById('ips').innerText = d.ips;
    } catch(e) {}
}

async function loadConfig() {
    try {
        const r = await fetch('/api/config');
        const d = await r.json();
        document.getElementById('zt-net').value = d.zerotier_net || '';
        document.getElementById('tg-token').value = d.telegram_token || '';
        document.getElementById('tg-chat').value = d.telegram_chat_id || '';
        document.getElementById('user').value = d.admin_user || '';
        document.getElementById('pass').value = d.admin_pass || '';
        document.getElementById('zt-id').innerText = d.zerotier_node_id || 'Не визначено';
    } catch(e) {}
}

async function saveConfig() {
    const payload = {
        zerotier_net: document.getElementById('zt-net').value,
        telegram_token: document.getElementById('tg-token').value,
        telegram_chat_id: document.getElementById('tg-chat').value,
        admin_user: document.getElementById('user').value,
        admin_pass: document.getElementById('pass').value
    };
    const r = await fetch('/api/config', {
        method:'POST',
        headers:{'Content-Type':'application/json'},
        body:JSON.stringify(payload)
    });
    const d = await r.json();
    document.getElementById('config-result').innerText = d.message;
}

async function scanWifi() {
    const box = document.getElementById('wifi-list');
    box.textContent = 'Сканування...';
    try {
        const r = await fetch('/api/scan');
        const d = await r.json();
        const networks = Array.isArray(d.networks) ? d.networks : [];
        if (!networks.length) {
            box.textContent = 'Мереж не знайдено.';
            return;
        }

        const table = document.createElement('table');
        const thead = document.createElement('thead');
        const headerRow = document.createElement('tr');
        for (const title of ['SSID', 'Сигнал', 'Захист', 'Статус', 'Пароль', 'Дія']) {
            const th = document.createElement('th');
            th.textContent = title;
            headerRow.appendChild(th);
        }
        thead.appendChild(headerRow);
        table.appendChild(thead);

        const tbody = document.createElement('tbody');
        networks.forEach((network, i) => {
            const n = network || {};
            const ssid = String(n.ssid ?? '');
            const signal = String(n.signal ?? '');
            const security = String(n.security ?? '');
            const isOpen = (!security || security === '--' || security === 'Відкрита');

            const row = document.createElement('tr');

            const ssidCell = document.createElement('td');
            const ssidLabel = document.createElement('b');
            ssidLabel.textContent = ssid;
            ssidCell.appendChild(ssidLabel);
            row.appendChild(ssidCell);

            const signalCell = document.createElement('td');
            signalCell.textContent = signal + '%';
            row.appendChild(signalCell);

            const securityCell = document.createElement('td');
            securityCell.textContent = security || 'Відкрита';
            row.appendChild(securityCell);

            const statusCell = document.createElement('td');
            statusCell.textContent = n.in_use ? '🟢' : '';
            row.appendChild(statusCell);

            const passwordCell = document.createElement('td');
            if (isOpen) {
                passwordCell.textContent = '-';
            } else {
                const passwordInput = document.createElement('input');
                passwordInput.type = 'password';
                passwordInput.id = 'pass-' + i;
                passwordInput.placeholder = 'Пароль';
                passwordInput.style.width = '100px';
                passwordInput.style.padding = '4px';
                passwordCell.appendChild(passwordInput);
            }
            row.appendChild(passwordCell);

            const actionCell = document.createElement('td');
            const button = document.createElement('button');
            button.type = 'button';
            button.style.padding = '4px 8px';
            button.style.fontSize = '12px';
            button.style.margin = '0';
            button.textContent = 'Підкл';
            button.addEventListener('click', () => connectWifi(ssid, isOpen, i));
            actionCell.appendChild(button);
            row.appendChild(actionCell);

            tbody.appendChild(row);
        });

        table.appendChild(tbody);
        box.replaceChildren(table);
    } catch(e) {
        box.textContent = 'Помилка сканування.';
    }
}

async function connectWifi(ssid, isOpen, idx) {
    let password = '';
    if (!isOpen) {
        const passInput = document.getElementById('pass-' + idx);
        if (passInput) password = passInput.value;
        if (!password) {
            alert('Введіть пароль для ' + ssid);
            return;
        }
    }
    alert('Запит на підключення до ' + ssid + ' відправлено...');
    try {
        const r = await fetch('/api/connect', {
            method:'POST',
            headers:{'Content-Type':'application/json'},
            body:JSON.stringify({ssid: ssid, password: password})
        });
        const d = await r.json();
        alert(d.message);
        updateStatus();
    } catch(e) {
        alert('Помилка підключення');
    }
}

async function forceScan() { await scanWifi(); }

async function loadLogs() {
    try {
        const r = await fetch('/api/logs');
        const d = await r.json();
        document.getElementById('logs').innerText = d.logs || 'Немає записів.';
    } catch(e) {}
}

async function control(action) {
    try {
        const r = await fetch('/api/control/' + action, { method:'POST' });
        const d = await r.json();
        if (!r.ok) alert(d.message || 'Не вдалося виконати команду.');
        setTimeout(updateStatus, 1000);
    } catch(e) {
        alert('Не вдалося зв’язатися з BUDDY.');
    }
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
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            return jsonify({"success": False, "message": "Очікується JSON object."}), 400

        updated = dict(config)
        for key in ("admin_user", "admin_pass", "telegram_token"):
            if key not in data:
                continue
            value = data[key]
            if not isinstance(value, str):
                return jsonify({"success": False, "message": f"Некоректне поле: {key}"}), 400
            if key in ("admin_pass", "telegram_token") and not value:
                continue
            if key == "admin_user" and not value:
                return jsonify({"success": False, "message": "Логін не може бути порожнім."}), 400
            if key == "admin_pass" and len(value) < 16:
                return jsonify({"success": False, "message": "Пароль має містити щонайменше 16 символів."}), 400
            updated[key] = value

        for key in ("telegram_chat_id", "zerotier_net"):
            if key in data:
                value = data[key]
                if not isinstance(value, str):
                    return jsonify({"success": False, "message": f"Некоректне поле: {key}"}), 400
                updated[key] = value

        temp_file = CONFIG_FILE + ".tmp"
        try:
            fd = os.open(temp_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(updated, f, indent=4, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(temp_file, 0o600)
            os.replace(temp_file, CONFIG_FILE)
        except Exception:
            logging.exception("Не вдалося зберегти конфігурацію")
            return jsonify({"success": False, "message": "Не вдалося зберегти налаштування."}), 500

        config = updated
        zt_net = config["zerotier_net"].strip()
        if zt_net:
            run_cmd(["zerotier-cli", "join", zt_net], timeout=10)
        return jsonify({"success": True, "message": "✅ Налаштування збережено."})

    result = dict(config)
    result["admin_pass"] = ""
    result["telegram_token"] = ""
    result["zerotier_node_id"] = get_zerotier_node_id()
    return jsonify(result)

@app.route("/api/scan")
@requires_auth
def api_scan():
    return jsonify({"networks": scan_all_wifi_networks()})

@app.route("/api/logs")
@requires_auth
def api_logs():
    logs = run_cmd(["journalctl", "-u", "wifi-failover.service", "-n", "50", "--no-pager"])
    return jsonify({"logs": logs})

@app.route("/api/control/<action>", methods=["POST"])
@requires_auth
def api_control(action):
    if action not in ("start", "stop", "restart"):
        return jsonify({"success": False, "message": "Невідома дія."}), 400
    try:
        result = subprocess.run(
            ["systemctl", action, "wifi-failover.service"],
            capture_output=True, text=True, timeout=20
        )
    except subprocess.TimeoutExpired:
        return jsonify({"success": False, "message": "Час очікування команди минув."}), 504
    except OSError:
        logging.exception("Не вдалося запустити systemctl")
        return jsonify({"success": False, "message": "Не вдалося запустити systemctl."}), 500
    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Команда systemctl завершилася помилкою.").strip()
        return jsonify({"success": False, "message": message}), 502
    return jsonify({"success": True, "message": "Команду виконано."})

@app.route("/api/connect", methods=["POST"])
@requires_auth
def api_connect():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"success": False, "message": "Очікується JSON object."}), 400

    ssid = data.get("ssid")
    password = data.get("password", "")
    if not isinstance(ssid, str) or not ssid or "\x00" in ssid:
        return jsonify({"success": False, "message": "Некоректний SSID."}), 400
    try:
        if len(ssid.encode("utf-8")) > 32:
            return jsonify({"success": False, "message": "SSID перевищує 32 байти."}), 400
    except UnicodeEncodeError:
        return jsonify({"success": False, "message": "Некоректне кодування SSID."}), 400
    if not isinstance(password, str):
        return jsonify({"success": False, "message": "Некоректний пароль Wi-Fi."}), 400
    if "\x00" in password:
        return jsonify({"success": False, "message": "Некоректний пароль Wi-Fi."}), 400

    cmd = ["nmcli", "device", "wifi", "connect", ssid, "ifname", WLAN_IFACE]
    if password:
        cmd.extend(["password", password])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return jsonify({"success": False, "message": "Час очікування підключення минув."}), 504
    except OSError:
        logging.exception("Не вдалося запустити nmcli")
        return jsonify({"success": False, "message": "Не вдалося запустити nmcli."}), 500

    if result.returncode != 0:
        message = (result.stderr or result.stdout or "Не вдалося підключитися до Wi-Fi.").strip()
        return jsonify({"success": False, "message": message}), 502
    return jsonify({"success": True, "message": result.stdout.strip() or "Підключено до Wi-Fi."})

if __name__ == "__main__":
    monitor_thread = threading.Thread(target=network_monitor_worker, daemon=True)
    monitor_thread.start()

    tg_thread = threading.Thread(target=telegram_worker, daemon=True)
    tg_thread.start()

    logging.info("BUDDY WSGI server starting on 0.0.0.0:8081")
    serve(app, host="0.0.0.0", port=8081, threads=8)
PYEOF

python3 -c 'from pathlib import Path; p=Path("/opt/buddy/app.py"); compile(p.read_text(encoding="utf-8"), str(p), "exec")'

echo "[+] Налаштування каналу польотного контролера для QGroundControl..."
FCU_DEVICE=""
if [[ -v BUDDY_FCU_DEVICE ]]; then FCU_DEVICE="$BUDDY_FCU_DEVICE"; fi
if [[ -z "$FCU_DEVICE" && -t 0 ]]; then
    read -r -p "USB/UART device [/dev/serial0]: " FCU_DEVICE || true
fi
if [[ -z "$FCU_DEVICE" ]]; then FCU_DEVICE=/dev/serial0; fi
if [[ ! "$FCU_DEVICE" =~ ^/dev/[A-Za-z0-9._/-]+$ ]]; then
    echo "[-] Некоректний serial device: $FCU_DEVICE"
    exit 1
fi

FCU_BAUD=""
if [[ -v BUDDY_FCU_BAUD ]]; then FCU_BAUD="$BUDDY_FCU_BAUD"; fi
if [[ -z "$FCU_BAUD" && -t 0 ]]; then
    read -r -p "UART baud rate [115200]: " FCU_BAUD || true
fi
if [[ -z "$FCU_BAUD" ]]; then FCU_BAUD=115200; fi
if [[ ! "$FCU_BAUD" =~ ^[0-9]{4,7}$ ]]; then
    echo "[-] Некоректна швидкість UART: $FCU_BAUD"
    exit 1
fi

QGC_UDP_PORT=14550
if [[ -v BUDDY_QGC_UDP_PORT ]]; then QGC_UDP_PORT="$BUDDY_QGC_UDP_PORT"; fi
if ! [[ "$QGC_UDP_PORT" =~ ^[0-9]+$ ]] || [ "$QGC_UDP_PORT" -lt 1 ] || [ "$QGC_UDP_PORT" -gt 65535 ]; then
    echo "[-] Некоректний UDP порт QGC: $QGC_UDP_PORT"
    exit 1
fi

echo "[+] Збирання MAVLink Router v4..."
MAVLINK_ROUTER_COMMIT="42529d55b665e0a9a29e424e186f514c56c2e5b5"
MAVLINK_ROUTER_SRC="$INSTALL_TMP_DIR/mavlink-router"
git clone --depth 1 --branch v4 --recurse-submodules https://github.com/mavlink-router/mavlink-router.git "$MAVLINK_ROUTER_SRC"
ACTUAL_MAVLINK_ROUTER_COMMIT="$(git -C "$MAVLINK_ROUTER_SRC" rev-parse HEAD)"
if [[ "$ACTUAL_MAVLINK_ROUTER_COMMIT" != "$MAVLINK_ROUTER_COMMIT" ]]; then
    echo "[-] MAVLink Router tag v4 має неочікуваний commit: $ACTUAL_MAVLINK_ROUTER_COMMIT"
    exit 1
fi
meson setup "$MAVLINK_ROUTER_SRC/build" "$MAVLINK_ROUTER_SRC" --buildtype=release --prefix=/usr/local -Dsysconfdir=/etc -Dsystemdsystemunitdir=/usr/lib/systemd/system
ninja -C "$MAVLINK_ROUTER_SRC/build"
ninja -C "$MAVLINK_ROUTER_SRC/build" install

if ! id -u buddy-mavlink >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin buddy-mavlink
fi
usermod -a -G dialout buddy-mavlink

install -d -o root -g dialout -m 0750 /etc/mavlink-router
cat > /etc/mavlink-router/main.conf <<EOF_MAVLINK
[UartEndpoint flight_controller]
Device = $FCU_DEVICE
Baud = $FCU_BAUD

[UdpEndpoint qgroundcontrol]
Mode = Server
Address = 0.0.0.0
Port = $QGC_UDP_PORT

[UdpEndpoint qgroundcontrol_broadcast]
Mode = Normal
Address = 255.255.255.255
Port = $QGC_UDP_PORT
EOF_MAVLINK
chown root:dialout /etc/mavlink-router/main.conf
chmod 640 /etc/mavlink-router/main.conf

cat > /etc/systemd/system/buddy-mavlink.service <<'EOF_MAVLINK_SERVICE'
[Unit]
Description=BUDDY MAVLink Router for QGroundControl
After=network.target

[Service]
Type=simple
User=buddy-mavlink
Group=dialout
ExecStart=/usr/local/bin/mavlink-routerd -c /etc/mavlink-router/main.conf
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF_MAVLINK_SERVICE

if [ ! -e /opt/buddy/config.json ]; then
    ADMIN_USER="admin"
    if [[ -v BUDDY_USER ]]; then ADMIN_USER="$BUDDY_USER"; fi
    ADMIN_PASS=""
    if [[ -v BUDDY_PASS ]]; then ADMIN_PASS="$BUDDY_PASS"; fi
    GENERATED_ADMIN_PASS=0
    if [ -z "$ADMIN_PASS" ]; then
        ADMIN_PASS="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
        GENERATED_ADMIN_PASS=1
    fi
    BUDDY_ADMIN_USER="$ADMIN_USER" BUDDY_ADMIN_PASS="$ADMIN_PASS" python3 - <<'PYEOF_CONFIG'
import json
import os

path = "/opt/buddy/config.json"
payload = {
    "admin_user": os.environ["BUDDY_ADMIN_USER"],
    "admin_pass": os.environ["BUDDY_ADMIN_PASS"],
    "telegram_token": "",
    "telegram_chat_id": "",
    "zerotier_net": ""
}
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=4, ensure_ascii=False)
    f.write("\n")
PYEOF_CONFIG
    if [ "$GENERATED_ADMIN_PASS" -eq 1 ]; then
        echo
        echo "[+] Веблогін: $ADMIN_USER"
        echo "[+] Тимчасовий пароль (збережіть його): $ADMIN_PASS"
    fi
fi
chmod 600 /opt/buddy/config.json

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

systemctl disable --now mavlink-router.service 2>/dev/null || true
systemctl daemon-reload
systemctl enable wifi-failover.service
systemctl restart wifi-failover.service
systemctl enable buddy-mavlink.service
systemctl restart buddy-mavlink.service

sleep 2

LOCAL_IPS=$(hostname -I 2>/dev/null || true)
ZT_IPS=$(ip -4 -o addr show 2>/dev/null | grep -E 'zt|zt[a-zA-Z0-9]' | awk '{print $4}' | cut -d/ -f1 || true)

echo
echo "======================================================"
echo "[+] BUDDY встановлено"
echo "[+] Flight controller: $FCU_DEVICE at $FCU_BAUD baud"
echo "[+] QGroundControl UDP port: $QGC_UDP_PORT"
echo
echo "[+] QGC same-LAN UDP broadcast discovery is enabled on port $QGC_UDP_PORT."
echo "[+] If auto-discovery is unavailable, add a QGC UDP link and set the Pi as remote host on port $QGC_UDP_PORT:"
for ip in $LOCAL_IPS; do
    echo "    $ip"
done
if [ -n "$ZT_IPS" ]; then
    echo
    echo "[+] ZeroTier Pi addresses:"
    for ip in $ZT_IPS; do
        echo "    $ip"
    done
fi
echo
echo "[+] BUDDY web panel:"
for ip in $LOCAL_IPS; do
    echo "    http://$ip:8081"
done
echo "======================================================"
systemctl --no-pager --full status wifi-failover.service || true
systemctl --no-pager --full status buddy-mavlink.service || true
echo "======================================================"

