#!/usr/bin/env bash
# NEXUS v7.3 - gateway auto-normalize ({cc}/{session}), pool always used, rotation toggle
set -euo pipefail

APP_DIR="${NEXUS_DIR:-/opt/nexus}"
MARKER="$APP_DIR/.installed"

[[ $EUID -ne 0 ]] && { echo "Root chahiye: sudo bash $0"; exit 1; }

mkdir -p "$APP_DIR"; cd "$APP_DIR"
echo "==> NEXUS v7.3 setup"

# purane instances band -> fresh start (duplicate Xvfb/profile lock se bachne ke liye)
pkill -f 'nexus_agent.py' 2>/dev/null || true
pkill -f 'xvfb-run' 2>/dev/null || true
sleep 1

if [[ ! -f "$MARKER" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 python3-venv python3-pip xvfb curl ca-certificates tzdata >/dev/null
  python3 -m venv .venv
  # shellcheck disable=SC1091
  . .venv/bin/activate
  pip install -q --upgrade pip
  pip install -q python-telegram-bot playwright python-dotenv
  echo "==> Chromium (2-4 min)"
  playwright install --with-deps chromium >/dev/null
  touch "$MARKER"
fi

# shellcheck disable=SC1091
. .venv/bin/activate

TOKENS_FILE="$APP_DIR/tokens.env"

# multi-token collect: tokens.env + purana .env, dedupe ke saath
declare -a TOKENS=()
while IFS= read -r _t; do
  [[ -z "$_t" ]] && continue
  _dup=0
  for _x in "${TOKENS[@]}"; do [[ "$_x" == "$_t" ]] && { _dup=1; break; }; done
  (( _dup )) || TOKENS+=("$_t")
done < <(
  { [[ -f "$TOKENS_FILE" ]] && awk '/^([A-Za-z0-9_]*BOT_[0-9]+_TOKEN|TG_BOT_TOKEN)=/{v=$0; sub(/^[^=]*=/,"",v); gsub(/[[:space:]]/,"",v); print v}' "$TOKENS_FILE"
    [[ -f "$APP_DIR/.env" ]] && awk '/^TG_BOT_TOKEN=/{v=$0; sub(/^[^=]*=/,"",v); print v; exit}' "$APP_DIR/.env"
  }
)

# token ho to prompt nahi. na ho to ek hi baar paste karwa ke save
if (( ${#TOKENS[@]} == 0 )); then
  echo
  echo "Koi token nahi mila. Paste karo (khali Enter = done):"
  while true; do
    read -r -s -p "TG_BOT_TOKEN: " _t; echo
    if [[ -z "${_t// /}" ]]; then
      (( ${#TOKENS[@]} )) && break
      echo "Khali hai, dobara."; continue
    fi
    [[ "$_t" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "Format galat."; continue; }
    TOKENS+=("$_t")
    read -r -p "Ek aur? (y/N): " _a || _a="n"
    [[ "${_a,,}" == y* ]] || break
  done
  umask 077; : > "$TOKENS_FILE"
  for _i in "${!TOKENS[@]}"; do printf 'BOT_%s_TOKEN=%s\n' "$((_i+1))" "${TOKENS[$_i]}" >> "$TOKENS_FILE"; done
  chmod 600 "$TOKENS_FILE"
  echo "${#TOKENS[@]} token save: $TOKENS_FILE"
fi

CHAT_ID=""
[[ -f "$APP_DIR/.env" ]] && CHAT_ID="$(awk '/^TG_CHAT_ID=/{v=$0; sub(/^[^=]*=/,"",v); print v; exit}' "$APP_DIR/.env")"

cat > "$APP_DIR/nexus_agent.py" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NEXUS v7.3

Gateway proxy (Oxylabs/Decodo/IPRoyal style) auto-normalize:
  customer- prefix, -cc-{cc}, -sessid-{session} khud lag jate hain.
Pool hamesha use hota hai, chahe ek hi loop ho. /rotation se control.

Env: TG_BOT_TOKEN (required), TG_CHAT_ID (optional)
"""

import asyncio
import base64
import hashlib
import html
import json
import logging
import os
import random
import re
import string
import time
import urllib.request
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

from telegram import InlineKeyboardButton, InlineKeyboardMarkup, Update
from telegram.ext import (
    Application, CallbackQueryHandler, CommandHandler, ContextTypes,
    ConversationHandler, MessageHandler, filters,
)
from playwright.async_api import async_playwright

try:
    from dotenv import load_dotenv
    load_dotenv(Path(__file__).resolve().parent / ".env")
except ImportError:
    pass

FALLBACK_TOKEN = ""
BOT_TOKEN = (os.environ.get("TG_BOT_TOKEN") or FALLBACK_TOKEN).strip()
ALLOWED_CHAT_ID = str(os.environ.get("TG_CHAT_ID", "")).strip()

BASE_DIR = Path(os.environ.get("NEXUS_DATA_DIR") or (Path(__file__).resolve().parent / "nexus_data"))
PROFILES_DIR = BASE_DIR / "profiles"
CACHE_DIR = BASE_DIR / "web_cache"
REPORT_DIR = BASE_DIR / "reports"
CONFIG_FILE = Path(os.environ.get("NEXUS_CONFIG") or (BASE_DIR / "profiles_config.json"))
for _d in (PROFILES_DIR, CACHE_DIR, REPORT_DIR):
    _d.mkdir(parents=True, exist_ok=True)

CACHE_TTL = 48 * 3600
CACHE_MAX_BODY = 3 * 1024 * 1024
FLOW_ATTEMPTS = 3
DWELL_MIN, DWELL_MAX = 16.0, 24.0
POST_DWELL_MIN, POST_DWELL_MAX = 5.0, 7.0
FPS_PER_PROXY = 5
DEFAULT_COOLDOWN = 65
NET_CAP = 400
PROBE_URL = "https://linkvertise.com/access/10771971/8NOuYBywZkIq"

GATEWAY_HOSTS = ("oxylabs", "smartproxy", "decodo", "iproyal", "brightdata", "proxy-cheap", "netnut")

BLOCKED_DOMAINS = ("clarity.ms", "hotjar.com", "scorecardresearch.com", "analytics.tiktok.com")

AD_HOSTS = ("doubleclick", "googlesyndication", "googleadservices", "adservice",
            "linkvertise", "link-to", "amazon-adsystem", "criteo", "taboola", "outbrain")

CONVERSION_HINTS = (
    "/access", "/view", "/complete", "/conversion", "/pixel", "/collect",
    "/track", "/impression", "/stat", "/count", "/api/v1", "lnk.to", "link-to.net",
)
CONVERSION_HOSTS = ("linkvertise", "link-to", "lnk.to", "loot-link", "lootlink", "lootlabs")

AD_SELECTORS = (
    'iframe[src*="taboola"]', 'div[id*="taboola"]', '[class*="taboola"]',
    'iframe[src*="doubleclick"]', 'iframe[id*="google_ads"]', 'ins.adsbygoogle',
    '[class*="advertisement"]', '[id*="ad-slot"]', '[data-ad-slot]', '[id^="ad-"]',
)

FP_FIELDS = (
    "user_agent", "platform", "vendor", "webgl_vendor", "webgl_renderer",
    "viewport", "screen", "device_scale_factor", "hardware_concurrency",
    "device_memory", "timezone", "locale",
)

TZ_ALIASES = {
    "Asia/Calcutta": "Asia/Kolkata", "Asia/Katmandu": "Asia/Kathmandu",
    "Europe/Kiev": "Europe/Kyiv", "Asia/Rangoon": "Asia/Yangon",
    "Asia/Saigon": "Asia/Ho_Chi_Minh", "America/Buenos_Aires": "America/Argentina/Buenos_Aires",
    "Atlantic/Faeroe": "Atlantic/Faroe", "Pacific/Ponape": "Pacific/Pohnpei",
}

COUNTRY_TZ = {
    "US": ("America/New_York", "en-US"), "CA": ("America/Toronto", "en-CA"),
    "GB": ("Europe/London", "en-GB"), "DE": ("Europe/Berlin", "de-DE"),
    "FR": ("Europe/Paris", "fr-FR"), "NL": ("Europe/Amsterdam", "nl-NL"),
    "IN": ("Asia/Kolkata", "en-IN"), "SG": ("Asia/Singapore", "en-SG"),
    "AU": ("Australia/Sydney", "en-AU"), "BR": ("America/Sao_Paulo", "pt-BR"),
    "JP": ("Asia/Tokyo", "ja-JP"), "AE": ("Asia/Dubai", "en-AE"),
    "ES": ("Europe/Madrid", "es-ES"), "IT": ("Europe/Rome", "it-IT"),
    "PL": ("Europe/Warsaw", "pl-PL"), "SE": ("Europe/Stockholm", "sv-SE"),
    "TR": ("Europe/Istanbul", "tr-TR"), "ID": ("Asia/Jakarta", "id-ID"),
    "MX": ("America/Mexico_City", "es-MX"), "RO": ("Europe/Bucharest", "ro-RO"),
}

CHROME_VERSIONS = ("130.0.0.0", "131.0.0.0", "132.0.0.0", "133.0.0.0")
GPU_WIN = [
    ("Google Inc. (NVIDIA)", "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0)"),
    ("Google Inc. (NVIDIA)", "ANGLE (NVIDIA, NVIDIA GeForce RTX 4060 Direct3D11 vs_5_0 ps_5_0)"),
    ("Google Inc. (NVIDIA)", "ANGLE (NVIDIA, NVIDIA GeForce GTX 1660 SUPER Direct3D11 vs_5_0 ps_5_0)"),
    ("Google Inc. (Intel)", "ANGLE (Intel, Intel(R) UHD Graphics 630 Direct3D11 vs_5_0 ps_5_0)"),
    ("Google Inc. (Intel)", "ANGLE (Intel, Intel(R) Iris(R) Xe Graphics Direct3D11 vs_5_0 ps_5_0)"),
    ("Google Inc. (AMD)", "ANGLE (AMD, AMD Radeon RX 6600 Direct3D11 vs_5_0 ps_5_0)"),
]
SCREENS = [(1920, 1080), (1600, 900), (1536, 864), (1440, 900), (1366, 768)]
CORES_MEM = [(4, 8), (8, 8), (8, 16), (12, 16), (16, 32)]

MOBILE_UA = ("Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
             "(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36")
MOBILE_GPU = ("Google Inc. (Qualcomm)", "ANGLE (Qualcomm, Adreno (TM) 730, OpenGL ES 3.2)")

PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
)

ACTIVE_PAGE = None
ACTIVE_CONTEXT = None
RUNNING_TASK = None
STOP_EVENT = asyncio.Event()
IS_RUNNING = False
PENDING = {}
CONFIRM_FUTURES = {}
CONFIRM_ENABLED = True
VERIFY_ENABLED = True
WARMUP_ENABLED = True
BLOCK_FONTS = False
PROBE_ENABLED = True
FORCE_ROTATE = False
DEVICE_MODE = "desktop"
REAL_IP = None
LAST_REPORT_PATH = None
LAST_NET = []
GEO_CACHE = {}

logging.basicConfig(format="%(asctime)s %(levelname)s %(name)s: %(message)s", level=logging.WARNING)


# ------------------------------------------------------------------ helpers

def gen_session_id(n=10):
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=n))


def esc(v):
    return html.escape(str(v), quote=False)


def short_err(exc):
    t = str(exc).strip()
    return (t.splitlines()[0] if t else "unknown")[:250]


def tz_same(a, b):
    if a == b or TZ_ALIASES.get(a) == b or TZ_ALIASES.get(b) == a:
        return True
    try:
        now = datetime.now()
        return ZoneInfo(a).utcoffset(now) == ZoneInfo(b).utcoffset(now)
    except Exception:
        return False


def gen_fp(country=None, mobile=False):
    cc = (country or random.choice(list(COUNTRY_TZ))).upper()[:2]
    tz, locale = COUNTRY_TZ.get(cc, ("America/New_York", "en-US"))
    if mobile:
        gv, gr = MOBILE_GPU
        return {
            "name": f"{cc.lower()}-m{random.randint(1000, 9999)}", "country": cc,
            "user_agent": MOBILE_UA, "platform": "Linux armv8l", "vendor": "Google Inc.",
            "webgl_vendor": gv, "webgl_renderer": gr,
            "viewport": {"width": 412, "height": 875}, "screen": {"width": 412, "height": 915},
            "device_scale_factor": 2.625, "hardware_concurrency": 8, "device_memory": 8,
            "timezone": tz, "locale": locale, "mobile": True,
        }
    if random.random() < 0.2:
        ua = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
              f"(KHTML, like Gecko) Chrome/{random.choice(CHROME_VERSIONS)} Safari/537.36")
        platform, gv, gr, dsf = "MacIntel", "Apple", "Apple M2", 2
    else:
        ua = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              f"(KHTML, like Gecko) Chrome/{random.choice(CHROME_VERSIONS)} Safari/537.36")
        platform = "Win32"
        gv, gr = random.choice(GPU_WIN)
        dsf = random.choice([1, 1, 1.25])
    w, h = random.choice(SCREENS)
    cores, mem = random.choice(CORES_MEM)
    return {
        "name": f"{cc.lower()}-{random.randint(1000, 9999)}", "country": cc,
        "user_agent": ua, "platform": platform, "vendor": "Google Inc.",
        "webgl_vendor": gv, "webgl_renderer": gr,
        "viewport": {"width": w, "height": h - 40}, "screen": {"width": w, "height": h},
        "device_scale_factor": dsf, "hardware_concurrency": cores, "device_memory": mem,
        "timezone": tz, "locale": locale,
    }


def geo_country(ip):
    if not ip:
        return None
    if ip in GEO_CACHE:
        return GEO_CACHE[ip]
    try:
        req = urllib.request.Request(f"https://ipwho.is/{ip}", headers={"User-Agent": "curl/8"})
        with urllib.request.urlopen(req, timeout=8) as r:
            d = json.loads(r.read().decode())
        cc = (d.get("country_code") or "").upper() if d.get("success") else None
    except Exception:
        cc = None
    GEO_CACHE[ip] = cc
    return cc


def proxy_host(url):
    if not url:
        return None
    return urlparse(url if "://" in url else f"http://{url}").hostname


def is_ip_literal(host):
    return bool(host and re.match(r"^\d+\.\d+\.\d+\.\d+$", host))


def is_gateway(url):
    h = (proxy_host(url) or "").lower()
    return any(g in h for g in GATEWAY_HOSTS)


def subnet_key(url):
    host = proxy_host(url) or ""
    return ".".join(host.split(".")[:3]) if is_ip_literal(host) else host


def load_config():
    if CONFIG_FILE.exists():
        try:
            data = json.loads(CONFIG_FILE.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            data = {}
        data.setdefault("profiles", {})
        data.setdefault("default_profile", "p1")
        data.setdefault("gap_seconds", 60)
        data.setdefault("data_saver", "off")
        data.setdefault("proxies", [])
        data.setdefault("cooldown_minutes", DEFAULT_COOLDOWN)
        data.setdefault("countries", ["us", "gb", "de", "fr", "nl", "in"])
        for e in data["proxies"]:
            e.setdefault("last_used", 0)
            e.setdefault("uses", 0)
            e.setdefault("throttled_until", 0)
            e.setdefault("country", "")
        return data
    cfg = {
        "default_profile": "p1", "data_saver": "off", "gap_seconds": 60,
        "cooldown_minutes": DEFAULT_COOLDOWN, "proxies": [],
        "countries": ["us", "gb", "de", "fr", "nl", "in"],
        "profiles": {"p1": {"proxy": None, "seed": random.randint(10000, 99999)}},
    }
    save_config(cfg)
    return cfg


def save_config(cfg):
    tmp = CONFIG_FILE.with_name(CONFIG_FILE.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(cfg, indent=2), encoding="utf-8")
    os.replace(tmp, CONFIG_FILE)


def normalize_gateway(raw, cc):
    """Oxylabs/Decodo style: customer- prefix, -cc-XX, -sessid-XXX khud lagao."""
    if "://" in raw:
        scheme, rest = raw.split("://", 1)
    else:
        scheme, rest = "http", raw
    if "@" not in rest:
        return raw
    creds, hostpart = rest.rsplit("@", 1)
    if ":" not in creds:
        return raw
    user, pwd = creds.split(":", 1)

    low_host = hostpart.lower()
    if not any(g in low_host for g in GATEWAY_HOSTS):
        return raw

    if "oxylabs" in low_host and not user.startswith("customer-"):
        user = "customer-" + user
    if "-cc-" not in user:
        user = f"{user}-cc-{(cc or 'us').lower()}"
    if "-sessid-" not in user and "-session-" not in user:
        user = f"{user}-sessid-{gen_session_id()}"

    return f"{scheme}://{user}:{pwd}@{hostpart}"


def parse_proxy(proxy_str, cc=None):
    if not proxy_str or proxy_str.lower() in ("none", "off", "clear", "direct", "-"):
        return None, "Direct"
    resolved = proxy_str.replace("{session}", gen_session_id())
    resolved = resolved.replace("{cc}", (cc or "us").lower())
    resolved = normalize_gateway(resolved, cc)
    parsed = urlparse(resolved if "://" in resolved else f"http://{resolved}")
    if not parsed.hostname:
        return None, "Direct (invalid proxy string)"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    server = f"{parsed.scheme}://{parsed.hostname}:{port}"
    proxy = {"server": server}
    if parsed.username:
        proxy["username"] = parsed.username
    if parsed.password:
        proxy["password"] = parsed.password
    return proxy, server


def is_authorized(update):
    if not ALLOWED_CHAT_ID:
        return True
    return str(update.effective_chat.id) == ALLOWED_CHAT_ID


def format_bytes(n):
    if n < 1024:
        return f"{n} B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f} KB"
    return f"{n / (1024 * 1024):.2f} MB"


def saver_mode(cfg):
    v = cfg.get("data_saver", "off")
    if isinstance(v, bool):
        return "pixel" if v else "off"
    return v if v in ("off", "pixel", "block") else "off"


async def pause(low, high):
    try:
        await asyncio.wait_for(STOP_EVENT.wait(), timeout=random.uniform(low, high))
    except asyncio.TimeoutError:
        pass


async def status(bot, chat_id, text, ok=None):
    mark = "✅ " if ok is True else ("❌ " if ok is False else ("⚠️ " if ok == "warn" else "• "))
    try:
        await bot.send_message(chat_id=chat_id, text=mark + text)
    except Exception:
        pass


def cache_paths(url):
    h = hashlib.sha256(url.encode()).hexdigest()
    return CACHE_DIR / f"{h}.bin", CACHE_DIR / f"{h}.json"


def cache_read(url):
    body_file, meta_file = cache_paths(url)
    if not (body_file.exists() and meta_file.exists()):
        return None
    try:
        meta = json.loads(meta_file.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if time.time() - float(meta.get("ts", 0)) > CACHE_TTL:
        return None
    try:
        return meta, body_file.read_bytes()
    except OSError:
        return None


def cache_write(url, headers, body):
    body_file, meta_file = cache_paths(url)
    try:
        body_file.write_bytes(body)
        meta_file.write_text(json.dumps({"headers": headers, "ts": time.time()}), encoding="utf-8")
    except OSError:
        pass


def resolve_persona(prof_data):
    return prof_data if prof_data.get("user_agent") else gen_fp("US")


def validate_fp(data):
    if not isinstance(data, dict):
        return False, "JSON object hona chahiye"
    missing = [f for f in FP_FIELDS if f not in data]
    if missing:
        return False, "missing: " + ", ".join(missing)
    for key in ("viewport", "screen"):
        box = data.get(key)
        if not isinstance(box, dict) or not isinstance(box.get("width"), int):
            return False, f"{key} me width/height integer"
    try:
        ZoneInfo(str(data.get("timezone")))
    except Exception:
        return False, "timezone invalid"
    return True, ""


def clear_lock(name):
    for f in ("SingletonLock", "SingletonCookie", "SingletonSocket"):
        try:
            (PROFILES_DIR / name / f).unlink()
        except OSError:
            pass


def fetch_real_ip():
    try:
        req = urllib.request.Request("https://api.ipify.org?format=json", headers={"User-Agent": "curl/8"})
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read().decode()).get("ip")
    except Exception:
        return None


def align_fp(prof_data, country):
    if not country or country not in COUNTRY_TZ:
        return prof_data, "tz: mapping nahi"
    tz, locale = COUNTRY_TZ[country]
    if tz_same(prof_data.get("timezone", ""), tz) and prof_data.get("locale") == locale:
        return prof_data, f"tz: {country} match"
    prof_data = dict(prof_data)
    prof_data["timezone"] = tz
    prof_data["locale"] = locale
    prof_data["country"] = country
    return prof_data, f"tz: {country} align"


def is_private(ip):
    if ip in ("0.0.0.0", "::", "::1"):
        return True
    p = ip.split(".")
    if len(p) != 4 or not all(x.isdigit() for x in p):
        return False
    a, b = int(p[0]), int(p[1])
    return a == 10 or (a == 192 and b == 168) or (a == 172 and 16 <= b <= 31) or a == 127


def is_conversion(url):
    u = url.lower()
    return any(h in u for h in CONVERSION_HINTS) and any(d in u for d in CONVERSION_HOSTS)


def add_proxy_entry(cfg, url):
    gateway = is_gateway(url) or "{cc}" in url
    if gateway:
        cl = cfg.get("countries") or ["us"]
        cc = cl[len(cfg["proxies"]) % len(cl)].upper()
    else:
        cc = geo_country(proxy_host(url)) or ""
    entry = {"url": url, "country": cc, "uses": 0, "last_used": 0, "throttled_until": 0,
             "fps": [gen_fp(cc, DEVICE_MODE == "mobile") for _ in range(FPS_PER_PROXY)] if cc else []}
    cfg["proxies"].append(entry)
    return entry


def mark_throttled(proxy_url, minutes=60):
    cfg = load_config()
    for e in cfg["proxies"]:
        if e["url"] == proxy_url:
            e["throttled_until"] = time.time() + (120 if is_gateway(e["url"]) else minutes * 60)
            break
    save_config(cfg)


# ------------------------------------------------------------------ stealth

def build_stealth_script(persona, seed):
    return f"""
    (() => {{
        const persona = {json.dumps(persona)};
        const seed = {seed};
        const def = (o, p, g) => Object.defineProperty(o, p, {{ get: g, configurable: true }});
        def(Navigator.prototype, 'webdriver', () => false);
        def(Navigator.prototype, 'platform', () => persona.platform);
        def(Navigator.prototype, 'vendor', () => persona.vendor);
        def(Navigator.prototype, 'hardwareConcurrency', () => persona.hardware_concurrency);
        def(Navigator.prototype, 'deviceMemory', () => persona.device_memory);
        def(Navigator.prototype, 'languages', () => Object.freeze([persona.locale, 'en']));
        def(Screen.prototype, 'width', () => persona.screen.width);
        def(Screen.prototype, 'height', () => persona.screen.height);
        def(Screen.prototype, 'availWidth', () => persona.viewport.width);
        def(Screen.prototype, 'availHeight', () => persona.viewport.height);
        def(Screen.prototype, 'colorDepth', () => 24);
        def(Screen.prototype, 'pixelDepth', () => 24);
        const mk = (n, f) => {{ const p = {{ name: n, description: 'Portable Document Format', filename: f, length: 1 }};
            p.item = i => (i === 0 ? p : null); p.namedItem = x => (x === n ? p : null); return p; }};
        const pl = ['PDF Viewer','Chrome PDF Viewer','Chromium PDF Viewer','Microsoft Edge PDF Viewer','WebKit built-in PDF']
            .map(n => mk(n, 'internal-pdf-viewer'));
        pl.refresh = () => undefined;
        def(Navigator.prototype, 'plugins', () => pl);
        if (!window.chrome) window.chrome = {{}};
        if (!window.chrome.runtime) window.chrome.runtime = {{}};
        const glp = {{ apply(t, c, a) {{
            if (a[0] === 37445) return persona.webgl_vendor;
            if (a[0] === 37446) return persona.webgl_renderer;
            return Reflect.apply(t, c, a); }} }};
        for (const C of [window.WebGLRenderingContext, window.WebGL2RenderingContext])
            if (C && C.prototype.getParameter) C.prototype.getParameter = new Proxy(C.prototype.getParameter, glp);
        const noise = (cv) => {{
            const x = cv.getContext && cv.getContext('2d');
            if (!x || !cv.width || !cv.height) return;
            for (let i = 0; i < 4; i++) {{
                const px = (seed * (i + 3)) % cv.width, py = (seed * (i + 7)) % cv.height;
                const a = 0.06 + ((seed + i) % 5) * 0.03;
                x.fillStyle = `rgba(${{seed % 7}}, ${{(seed * 3) % 7}}, ${{(seed * 11) % 7}}, ${{a}})`;
                x.fillRect(px, py, 1, 1);
            }} }};
        const od = HTMLCanvasElement.prototype.toDataURL;
        HTMLCanvasElement.prototype.toDataURL = function () {{ noise(this); return od.apply(this, arguments); }};
        const ob = HTMLCanvasElement.prototype.toBlob;
        HTMLCanvasElement.prototype.toBlob = function () {{ noise(this); return ob.apply(this, arguments); }};
        const og = CanvasRenderingContext2D.prototype.getImageData;
        CanvasRenderingContext2D.prototype.getImageData = function () {{
            const d = og.apply(this, arguments);
            try {{ const px = d.data; if (px && px.length >= 4) {{
                const i = (seed % 97) * 4; if (i + 3 < px.length) px[i + 3] = px[i + 3] ^ 1; }} }} catch (e) {{}}
            return d; }};
    }})();
    """


# ------------------------------------------------------------------ verify

FP_PROBE_JS = """() => {
    const c = document.createElement('canvas'); c.width = 220; c.height = 50;
    const x = c.getContext('2d'); x.textBaseline = 'top'; x.font = '14px Arial';
    x.fillStyle = '#f60'; x.fillRect(0, 0, 120, 25); x.fillStyle = '#069'; x.fillText('Nexus!', 2, 15);
    const gl = document.createElement('canvas').getContext('webgl');
    const dbg = gl && gl.getExtension('WEBGL_debug_renderer_info');
    return { ua: navigator.userAgent, platform: navigator.platform, vendor: navigator.vendor,
        cores: navigator.hardwareConcurrency, mem: navigator.deviceMemory,
        langs: (navigator.languages || []).join(','), webdriver: navigator.webdriver,
        plugins: navigator.plugins ? navigator.plugins.length : 0,
        chromeObj: !!(window.chrome && window.chrome.runtime),
        screen: screen.width + 'x' + screen.height,
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
        gpuRenderer: dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : null };
}"""


async def probe_exit_ip(page):
    ips = {}
    try:
        await page.goto("https://1.1.1.1/cdn-cgi/trace", wait_until="domcontentloaded", timeout=20000)
        m = re.search(r"^ip=(.+)$", await page.inner_text("body"), re.M)
        if m:
            ips["cloudflare"] = m.group(1).strip()
    except Exception:
        pass
    try:
        await page.goto("https://api.ipify.org?format=json", wait_until="domcontentloaded", timeout=20000)
        ips["ipify"] = json.loads(await page.inner_text("body")).get("ip")
    except Exception:
        pass
    return ips


async def probe_geo(page, ip):
    if not ip:
        return {}
    try:
        await page.goto(f"https://ipwho.is/{ip}", wait_until="domcontentloaded", timeout=12000)
        d = json.loads(await page.inner_text("body"))
        if not d.get("success"):
            return {}
        return {"country": d.get("country_code"), "city": d.get("city")}
    except Exception:
        return {}


async def probe_webrtc(page):
    try:
        return await page.evaluate("""async () => {
            const f = new Set();
            try {
                const pc = new RTCPeerConnection({ iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] });
                pc.createDataChannel('n');
                await pc.setLocalDescription(await pc.createOffer());
                await new Promise(r => setTimeout(r, 2500));
                ((pc.localDescription && pc.localDescription.sdp) || '').match(/\\d+\\.\\d+\\.\\d+\\.\\d+/g)?.forEach(i => f.add(i));
                pc.close();
            } catch (e) {}
            return [...f];
        }""")
    except Exception:
        return []


async def verify_identity(page, persona, proxy_display, is_direct=False):
    r = {"checks": [], "fatal": [], "warnings": []}
    ips = await probe_exit_ip(page)
    exit_ip = ips.get("cloudflare") or ips.get("ipify")
    r["exit_ip"] = exit_ip
    r["geo"] = await probe_geo(page, exit_ip)

    if not ips:
        r["fatal"].append("exit IP nahi mila - proxy/network dead")
        r["checks"].append(("proxy reachable", "yes", "no", False))
    else:
        r["checks"].append(("proxy reachable", "yes", "yes", True))
        if len(ips) == 2 and ips["cloudflare"] != ips["ipify"]:
            r["warnings"].append("do source alag IP - rotating")

    if exit_ip and REAL_IP:
        if is_direct:
            r["checks"].append(("direct exit = real ip", REAL_IP, exit_ip, exit_ip == REAL_IP))
        elif exit_ip == REAL_IP:
            r["fatal"].append(f"LEAK: exit IP = real IP ({REAL_IP})")
            r["checks"].append(("ip != real ip", REAL_IP, exit_ip, False))
        else:
            r["checks"].append(("ip != real ip", REAL_IP, exit_ip, True))

    try:
        fp = await page.evaluate(FP_PROBE_JS)
    except Exception as exc:
        r["fatal"].append(f"fp probe fail: {short_err(exc)}")
        fp = {}

    if fp:
        for name, exp, act in (
            ("user_agent", persona["user_agent"], fp.get("ua")),
            ("platform", persona["platform"], fp.get("platform")),
            ("vendor", persona["vendor"], fp.get("vendor")),
            ("cores", persona["hardware_concurrency"], fp.get("cores")),
            ("mem", persona["device_memory"], fp.get("mem")),
            ("screen", f"{persona['screen']['width']}x{persona['screen']['height']}", fp.get("screen")),
            ("languages", persona["locale"], (fp.get("langs") or "").split(",")[0]),
            ("gpu_renderer", persona["webgl_renderer"], fp.get("gpuRenderer")),
            ("webdriver=false", False, fp.get("webdriver")),
        ):
            ok = exp == act
            r["checks"].append((name, exp, act, ok))
            if not ok:
                r["fatal"].append(f"mismatch {name}: {act!r} != {exp!r}")

        tz_ok = tz_same(persona["timezone"], fp.get("tz") or "")
        r["checks"].append(("timezone", persona["timezone"], fp.get("tz"), tz_ok))
        if not tz_ok:
            r["fatal"].append(f"mismatch timezone: {fp.get('tz')!r}")
        r["checks"].append(("plugins > 0", ">0", fp.get("plugins"), (fp.get("plugins") or 0) > 0))
        r["checks"].append(("chrome.runtime", True, fp.get("chromeObj"), bool(fp.get("chromeObj"))))

    gc = (r["geo"] or {}).get("country")
    fc = persona.get("country")
    if gc and fc:
        r["checks"].append(("geo match", fc, gc, gc == fc))
        if gc != fc:
            r["warnings"].append(f"proxy {gc} vs fingerprint {fc}")

    pub = [ip for ip in await probe_webrtc(page) if not is_private(ip)]
    r["checks"].append(("webrtc leak", "none", ", ".join(pub) or "none", not pub))

    passed = sum(1 for c in r["checks"] if c[3])
    r["score"] = f"{passed}/{len(r['checks'])}"
    r["proxy_pass"] = is_direct or not any("LEAK" in f or "nahi mila" in f for f in r["fatal"])
    r["fp_pass"] = not any("mismatch" in f or "probe fail" in f for f in r["fatal"])
    r["verdict"] = "PASS" if (r["proxy_pass"] and r["fp_pass"]) else "FAIL"
    return r


def format_verify(vr, label):
    lines = [f"Verify {esc(label)} - {vr['verdict']} ({esc(vr['score'])})"]
    if vr.get("exit_ip"):
        g = vr.get("geo") or {}
        lines.append(f"Exit: {esc(vr['exit_ip'])}" + (f" | {esc(g.get('city'))}, {esc(g.get('country'))}" if g.get("country") else ""))
    for n, e, a, ok in vr["checks"]:
        if not ok:
            lines.append(f"❌ {esc(n)}: {esc(a)} (chahiye {esc(e)})")
    for w in vr["warnings"]:
        lines.append(f"⚠️ {esc(w)}")
    if vr["verdict"] == "PASS":
        lines.append("✅ sab check OK")
    return "\n".join(lines)[:4000]


# ------------------------------------------------------------------ browser

async def send_ss(bot, chat_id, page, caption):
    try:
        img = await page.screenshot(type="jpeg", quality=70, timeout=15000)
        await bot.send_photo(chat_id=chat_id, photo=img, caption=caption[:1024])
    except Exception as exc:
        await bot.send_message(chat_id=chat_id, text=f"{caption}\n(ss fail: {short_err(exc)})")


async def setup_context(p, profile_name, prof_data, override_proxy, saver):
    persona = resolve_persona(prof_data)
    seed = prof_data.get("seed", random.randint(10000, 99999))
    raw_proxy = override_proxy if override_proxy is not None else prof_data.get("proxy")
    proxy_cfg, proxy_display = parse_proxy(raw_proxy, persona.get("country"))
    if raw_proxy and proxy_cfg is None:
        raise RuntimeError(f"proxy invalid: {raw_proxy}")

    stats = {"proxy_bytes": 0, "saved_bytes": 0, "cache_hits": 0, "blocked": 0,
             "conv": [], "ads": 0, "net": []}

    def log_net(method, rtype, url, decision):
        if len(stats["net"]) < NET_CAP:
            stats["net"].append({"m": method, "t": rtype, "u": url[:180], "d": decision, "s": None, "n": 0})

    mobile = bool(persona.get("mobile"))
    context = await p.chromium.launch_persistent_context(
        user_data_dir=str(PROFILES_DIR / profile_name), headless=False, proxy=proxy_cfg,
        viewport=persona["viewport"], user_agent=persona["user_agent"], locale=persona["locale"],
        timezone_id=persona["timezone"], device_scale_factor=persona.get("device_scale_factor", 1),
        is_mobile=mobile, has_touch=mobile,
        args=["--disable-blink-features=AutomationControlled", "--no-sandbox",
              "--webrtc-ip-handling-policy=disable_non_proxied_udp", "--enforce-webrtc-ip-permission-check",
              "--disable-dev-shm-usage", "--enable-unsafe-swiftshader"],
    )
    await context.add_init_script(build_stealth_script(persona, seed))

    async def route_handler(route):
        req = route.request
        url = req.url
        low = url.lower()
        rt = req.resource_type
        if any(b in low for b in BLOCKED_DOMAINS):
            stats["blocked"] += 1
            log_net(req.method, rt, url, "abort-tracker")
            await route.abort()
            return
        if BLOCK_FONTS and rt == "font":
            stats["blocked"] += 1
            log_net(req.method, rt, url, "abort-font")
            await route.abort()
            return
        if saver == "block" and rt in ("image", "media"):
            stats["blocked"] += 1
            log_net(req.method, rt, url, "abort-saver")
            await route.abort()
            return
        if saver == "pixel" and rt == "image":
            if any(a in low for a in AD_HOSTS):
                log_net(req.method, rt, url, "pass-adimg")
                await route.continue_()
                return
            stats["blocked"] += 1
            log_net(req.method, rt, url, "pixel")
            await route.fulfill(status=200, body=PIXEL_PNG,
                                headers={"content-type": "image/png", "cache-control": "public, max-age=3600"})
            return
        if saver == "pixel" and rt == "media":
            stats["blocked"] += 1
            log_net(req.method, rt, url, "abort-media")
            await route.abort()
            return
        if saver != "off" and req.method == "GET" and rt in ("script", "stylesheet"):
            cached = cache_read(url)
            if cached is not None:
                meta, body = cached
                stats["cache_hits"] += 1
                stats["saved_bytes"] += len(body)
                log_net(req.method, rt, url, "cache")
                await route.fulfill(status=200, headers=meta.get("headers", {}), body=body)
                return
            try:
                resp = await asyncio.wait_for(route.fetch(), timeout=20)
                body = await resp.body()
                stats["proxy_bytes"] += len(body)
                log_net(req.method, rt, url, "fetch")
                headers = dict(resp.headers)
                headers.pop("content-encoding", None)
                headers.pop("content-length", None)
                if resp.status == 200 and len(body) < CACHE_MAX_BODY:
                    cache_write(url, headers, body)
                await route.fulfill(status=resp.status, headers=headers, body=body)
                return
            except Exception:
                log_net(req.method, rt, url, "fetch-fail")
                await route.continue_()
                return
        log_net(req.method, rt, url, "pass")
        await route.continue_()

    def on_response(response):
        try:
            if response.request.resource_type in ("script", "stylesheet"):
                return
            cl = response.headers.get("content-length")
            size = int(cl) if cl and cl.isdigit() else 0
            stats["proxy_bytes"] += size
            if is_conversion(response.url):
                stats["conv"].append((response.status, response.url[:160]))
            for e in reversed(stats["net"]):
                if e["u"][:110] == response.url[:110]:
                    e["s"] = response.status
                    e["n"] = size
                    break
        except Exception:
            pass

    context.on("response", on_response)
    await context.route("**/*", route_handler)
    return context, proxy_display, stats, persona


async def launch_with_fallback(p, candidates, saver):
    last = None
    seen = set()
    for profile, proxy in candidates:
        if (profile, proxy) in seen:
            continue
        seen.add((profile, proxy))
        cfg = load_config()
        pd = cfg["profiles"].get(profile)
        if pd is None:
            continue
        pd["seed"] = random.randint(10000, 99999)
        try:
            ctx, disp, stats, persona = await setup_context(p, profile, pd, proxy, saver)
            return ctx, profile, proxy, disp, stats, persona
        except Exception as exc:
            last = exc
            clear_lock(profile)
    raise RuntimeError(f"har identity fail: {last}")


async def goto_with_retry(page, url, tries=2):
    last = None
    for _ in range(tries):
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=35000)
            try:
                await page.wait_for_function("document.readyState === 'complete'", timeout=15000)
            except Exception:
                pass
            return
        except Exception as exc:
            last = exc
            await pause(1.5, 2.5)
    raise last


CONSENT_SELECTORS = (
    '#qc-cmp2-container button[mode="primary"]', '#qc-cmp2-ui button[mode="primary"]',
    'button.qc-cmp2-consent-button', '#onetrust-accept-btn-handler',
    '[aria-label="Accept"]', '[aria-label="Accept all"]',
    'button:has-text("ACCEPT")', 'button:has-text("Accept all")', 'button:has-text("Agree")',
)

POPUP_SELECTORS = (
    '[role="dialog"] button:has-text("Skip")',
    '[class*="modal"] button:has-text("Skip")',
    '[data-testid*="modal"] button:has-text("Skip")',
    'button:has-text("Skip timer")',
    'button:has-text("No thanks")',
    'button:has-text("Not now")',
    '[role="dialog"] [aria-label="Close"]',
    '[role="dialog"] button[aria-label*="lose"]',
    '[class*="modal"] [aria-label="Close"]',
)

CHALLENGE_MARKS = ("just a moment", "verify you are human", "checking your browser", "attention required")


async def dismiss_consent(page):
    for _ in range(2):
        for sel in CONSENT_SELECTORS:
            try:
                loc = page.locator(sel).first
                if await loc.is_visible():
                    await loc.click(timeout=1500)
                    await asyncio.sleep(0.5)
                    return True
            except Exception:
                continue
    try:
        await page.evaluate("""() => {
            for (const id of ['qc-cmp2-container','onetrust-consent-sdk','cmp-container','cookie-banner'])
                { const el = document.getElementById(id); if (el) el.remove(); }
            document.querySelectorAll('[class*="cookie"],[class*="consent"],[id*="cmp"]').forEach(el => {
                const p = getComputedStyle(el).position;
                if (p === 'fixed' || p === 'sticky') el.remove();
            });
        }""")
    except Exception:
        pass
    return False


async def dismiss_popups(page, limit=3):
    closed = 0
    for _ in range(limit):
        hit = False
        for sel in POPUP_SELECTORS:
            try:
                loc = page.locator(sel).first
                if await loc.is_visible():
                    await loc.click(timeout=1500)
                    closed += 1
                    hit = True
                    await asyncio.sleep(0.6)
                    break
            except Exception:
                continue
        if not hit:
            break
    return closed


async def wait_challenge(page, timeout=25):
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        try:
            title = (await page.title()).lower()
            body = (await page.inner_text("body"))[:400].lower()
        except Exception:
            await asyncio.sleep(1)
            continue
        if not any(m in title or m in body for m in CHALLENGE_MARKS):
            return True
        await asyncio.sleep(1.5)
    return False


async def detect_wait_limit(page):
    try:
        body = (await page.inner_text("body")).lower()
    except Exception:
        return None
    if not ("wait" in body or "try again" in body or "limit" in body):
        return None
    m = re.search(r"(\d{1,3}):(\d{2})", body)
    if m:
        return int(m.group(1))
    m = re.search(r"(\d{1,3})\s*(minute|min)", body)
    if m:
        return int(m.group(1))
    return None


async def count_ads(page):
    total = 0
    for sel in AD_SELECTORS:
        try:
            total += await page.locator(sel).count()
        except Exception:
            pass
    return total


async def human_idle(page, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end and not STOP_EVENT.is_set():
        try:
            await page.mouse.move(random.randint(80, 700), random.randint(100, 600), steps=random.randint(4, 10))
        except Exception:
            pass
        await asyncio.sleep(random.uniform(0.7, 1.7))
        if random.random() < 0.45:
            try:
                await page.mouse.wheel(0, random.choice([-140, 120, 220]))
            except Exception:
                pass


async def nudge_ads(page):
    try:
        height = await page.evaluate("Math.min(document.body.scrollHeight, 2600)")
        y = 0
        while y < height:
            await page.mouse.wheel(0, 320)
            y += 320
            await asyncio.sleep(random.uniform(0.35, 0.8))
            if STOP_EVENT.is_set():
                return
        await page.evaluate("window.scrollTo({ top: 0, behavior: 'smooth' })")
        await asyncio.sleep(0.8)
    except Exception:
        pass


async def locate_any(page, selector, timeout_ms):
    deadline = time.monotonic() + timeout_ms / 1000
    while time.monotonic() < deadline:
        if STOP_EVENT.is_set():
            return None, None
        for frame in page.frames:
            try:
                loc = frame.locator(selector).first
                if await loc.count() and await loc.is_visible():
                    return frame, loc
            except Exception:
                continue
        await asyncio.sleep(0.25)
    return None, None


async def human_click(page, frame, locator):
    box = await locator.bounding_box()
    if box:
        ox = oy = 0.0
        if frame != page.main_frame:
            try:
                fb = await frame.frame_element().bounding_box()
                if fb:
                    ox, oy = fb["x"], fb["y"]
            except Exception:
                pass
        x = ox + box["x"] + box["width"] * random.uniform(0.25, 0.75)
        y = oy + box["y"] + box["height"] * random.uniform(0.25, 0.75)
        for _ in range(random.randint(1, 3)):
            await page.mouse.move(x + random.randint(-40, 40), y + random.randint(-25, 25), steps=random.randint(3, 7))
            await asyncio.sleep(random.uniform(0.08, 0.25))
        await page.mouse.move(x, y, steps=random.randint(5, 11))
        await asyncio.sleep(random.uniform(0.15, 0.45))
    try:
        await locator.click(timeout=5000)
    except Exception:
        await dismiss_consent(page)
        await dismiss_popups(page, 1)
        try:
            await locator.click(timeout=4000)
        except Exception:
            await locator.click(timeout=4000, force=True)


STEPS = (
    ("Step 1: Watch Ads", 'lv-membership-plan-option:nth-of-type(4) [data-testid="lv-membership-plan-option-wrapper-btn"]', 15000),
    ("Step 2: Continue", '[data-testid="action-wall-continue-action-btn"]', 12000),
    ("Step 3: Skip Ad (1/3)", '[data-testid="lv-lib-carousel-skip-btn"], [data-testid="lv-chip"]', 45000),
    ("Step 4: Skip Ad (2/3)", '[data-testid="lv-lib-carousel-skip-btn"], [data-testid="lv-chip"]', 45000),
    ("Step 5: Skip Ad (3/3)", '[data-testid="lv-lib-carousel-skip-btn"], [data-testid="lv-chip"]', 45000),
    ("Step 6: Open Here", 'ui-card button.ui-button', 15000),
)


async def wait_beacon(stats, timeout=25):
    start = time.monotonic()
    while time.monotonic() - start < timeout and not STOP_EVENT.is_set():
        if any(200 <= s < 400 for s, _ in stats["conv"]):
            return stats["conv"]
        await asyncio.sleep(0.5)
    return stats["conv"]


async def attempt_flow(bot, chat_id, page, target_url, run_label, attempt, stats, proxy_url):
    await status(bot, chat_id, f"{run_label}: page load (try {attempt})")
    await goto_with_retry(page, target_url)
    await pause(0.8, 1.6)

    if not await wait_challenge(page):
        await send_ss(bot, chat_id, page, f"❌ {run_label}: challenge se bahar nahi nikla")
        stats["need_new"] = True
        return False
    await status(bot, chat_id, f"{run_label}: page khula", True)

    wait_min = await detect_wait_limit(page)
    if wait_min:
        await send_ss(bot, chat_id, page, f"⏳ {run_label}: IP LIMIT — {wait_min} min wait")
        stats["counted"] = f"IP LIMIT {wait_min}min"
        stats["limited"] = True
        stats["need_new"] = True
        if proxy_url:
            mark_throttled(proxy_url, max(wait_min, 60))
        return True

    await dismiss_consent(page)
    closed = await dismiss_popups(page)
    if closed:
        await status(bot, chat_id, f"{run_label}: {closed} popup hataya", True)

    stats["ads"] = await count_ads(page)
    await status(bot, chat_id, f"{run_label}: {stats['ads']} ad slot", stats["ads"] > 0)
    if stats["ads"]:
        await nudge_ads(page)
        closed = await dismiss_popups(page)
        if closed:
            await status(bot, chat_id, f"{run_label}: {closed} popup hataya (scroll ke baad)", True)

    for label, selector, timeout in STEPS:
        if STOP_EVENT.is_set():
            return False

        if label.startswith("Step 3"):
            _, carousel = await locate_any(page, "lv-lib-carousel, [class*='carousel'], [data-testid*='carousel']", 20000)
            if carousel:
                await status(bot, chat_id, f"{run_label}: carousel ready", True)
            else:
                await status(bot, chat_id, f"{run_label}: carousel nahi aaya", "warn")

        await status(bot, chat_id, f"{run_label}: {label} dhoondh raha hoon")
        frame, locator = await locate_any(page, selector, timeout)
        if locator is None:
            for _ in range(2):
                closed = await dismiss_popups(page)
                if not closed:
                    break
                await status(bot, chat_id, f"{run_label}: {closed} popup hataya, {label} dobara", True)
                frame, locator = await locate_any(page, selector, timeout // 2)
                if locator:
                    break
        if locator is None:
            if STOP_EVENT.is_set():
                await status(bot, chat_id, f"{run_label}: stop kiya gaya {label} par", False)
            else:
                await send_ss(bot, chat_id, page, f"❌ {run_label}: {label} {timeout // 1000}s me nahi mila")
            return False
        await status(bot, chat_id, f"{run_label}: {label} mila", True)

        for close_sel in ('[aria-label="Close"]', "button.close"):
            try:
                cb = page.locator(close_sel).first
                if await cb.is_visible():
                    await cb.click(timeout=1000)
                    await asyncio.sleep(0.3)
                    break
            except Exception:
                pass

        try:
            before = await page.evaluate("document.body.innerText.length")
        except Exception:
            before = 0
        before_url = page.url
        try:
            await locator.evaluate("el => { el.style.outline = '4px solid #ff0033'; }")
        except Exception:
            pass

        await send_ss(bot, chat_id, page, f"🖱️ {run_label}: {label} click")
        await human_click(page, frame, locator)
        await pause(1.4, 2.4)

        try:
            after = await page.evaluate("document.body.innerText.length")
        except Exception:
            after = before
        ok = (page.url != before_url) or (abs(after - before) > 5)
        markup = InlineKeyboardMarkup([[InlineKeyboardButton("🟩 VERIFIED", callback_data="cb:nop")]]) if ok else None
        await bot.send_message(chat_id=chat_id, reply_markup=markup,
                               text=f"{'✅ VERIFIED' if ok else '⚠️ CLICKED (page change nahi)'} — {run_label} {label}")
        if not ok:
            await dismiss_popups(page, 1)

    await status(bot, chat_id, f"{run_label}: target tab ka intezaar")
    await pause(2.0, 3.0)
    target = page
    try:
        others = [pg for pg in page.context.pages if pg is not page]
        if others:
            target = others[-1]
            await target.bring_to_front()
            await target.wait_for_load_state("load", timeout=25000)
            await status(bot, chat_id, f"{run_label}: target tab khula", True)
    except Exception:
        await status(bot, chat_id, f"{run_label}: target tab detect nahi hua", "warn")

    await status(bot, chat_id, f"{run_label}: beacon ka intezaar (25s)")
    hits = await wait_beacon(stats, timeout=25)

    await status(bot, chat_id, f"{run_label}: dwell {int(DWELL_MIN)}-{int(DWELL_MAX)}s")
    await human_idle(page, random.uniform(DWELL_MIN, DWELL_MAX))

    ls = ""
    try:
        ls = await page.evaluate(
            "() => Object.keys(localStorage).filter(k => /access|view|complete|plan|pass/i.test(k)).slice(0,6).join(',')")
    except Exception:
        pass

    good = [h for h in hits if 200 <= h[0] < 400]
    if good:
        stats["counted"] = f"COUNTED ({good[0][0]})"
    elif hits:
        stats["counted"] = f"beacon error ({hits[0][0]})"
        stats["need_new"] = True
    else:
        stats["counted"] = "NO BEACON"
        stats["need_new"] = True
    if ls:
        stats["counted"] += f" | ls:{ls[:50]}"

    await status(bot, chat_id, f"{run_label}: {stats['counted']}", bool(good))
    await status(bot, chat_id, f"{run_label}: extra {int(POST_DWELL_MIN)}-{int(POST_DWELL_MAX)}s settle")
    await human_idle(page, random.uniform(POST_DWELL_MIN, POST_DWELL_MAX))

    await send_ss(bot, chat_id, target, f"{'✅' if good else '⚠️'} COMPLETED {run_label}\n{stats['counted']}\nFinal: {target.url}")
    return True


async def execute_steps(bot, chat_id, page, target_url, run_label, stats, proxy_url):
    for attempt in range(1, FLOW_ATTEMPTS + 1):
        if STOP_EVENT.is_set():
            return False
        if await attempt_flow(bot, chat_id, page, target_url, run_label, attempt, stats, proxy_url):
            return True
        if attempt < FLOW_ATTEMPTS and not STOP_EVENT.is_set():
            await status(bot, chat_id, f"{run_label}: retry {attempt}/{FLOW_ATTEMPTS - 1} — reload", False)
            await pause(2.5, 4.0)
    if not STOP_EVENT.is_set():
        await status(bot, chat_id, f"{run_label}: {FLOW_ATTEMPTS} attempts fail", False)
        stats["need_new"] = True
    return False


async def ask_continue(bot, chat_id, text):
    if not CONFIRM_ENABLED:
        return True
    fut = asyncio.get_running_loop().create_future()
    CONFIRM_FUTURES[chat_id] = fut
    kb = InlineKeyboardMarkup([[
        InlineKeyboardButton("🟩 Aage badho", callback_data="cf:go"),
        InlineKeyboardButton("🟥 Ruk jao", callback_data="cf:stop")]])
    msg = await bot.send_message(chat_id=chat_id, text=text, reply_markup=kb)
    try:
        choice = await asyncio.wait_for(fut, timeout=45)
    except asyncio.TimeoutError:
        choice = "go"
    finally:
        CONFIRM_FUTURES.pop(chat_id, None)
    try:
        await msg.edit_reply_markup(None)
    except Exception:
        pass
    return choice == "go"


async def gap_wait(bot, chat_id, seconds):
    left = seconds
    while left > 0 and not STOP_EVENT.is_set():
        chunk = min(15, left)
        await pause(chunk, chunk + 1)
        left -= chunk
        if left > 0:
            await status(bot, chat_id, f"⏳ Gap — {left}s baaki")
    return not STOP_EVENT.is_set()


async def on_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if q.data == "cb:nop":
        return
    fut = CONFIRM_FUTURES.get(update.effective_chat.id)
    if fut and not fut.done():
        fut.set_result("go" if q.data == "cf:go" else "stop")


# ------------------------------------------------------------------ rotation

def choose_identity(cfg, iteration, base_profile, rotate):
    entries = cfg.get("proxies", [])

    if not entries:
        proxy = cfg["profiles"].get(base_profile, {}).get("proxy")
        prof = dict(cfg["profiles"].get(base_profile) or {})
        cc = geo_country(proxy_host(proxy) or REAL_IP)
        if not prof.get("user_agent"):
            prof.update({k: v for k, v in gen_fp(cc or "US", DEVICE_MODE == "mobile").items() if k != "name"})
        if cc:
            prof, _ = align_fp(prof, cc)
        prof["seed"] = random.randint(10000, 99999)
        cfg["profiles"][base_profile] = prof
        save_config(cfg)
        return base_profile, proxy, "pool khaali — direct"

    now = time.time()
    cd = cfg.get("cooldown_minutes", DEFAULT_COOLDOWN) * 60
    fresh = [e for e in entries
             if now - e.get("last_used", 0) > cd and e.get("throttled_until", 0) < now]
    pool = fresh or entries
    note_cd = "" if fresh else " | SAB COOLDOWN — purana uthaya"

    entry = min(pool, key=lambda e: (e.get("last_used", 0), e.get("uses", 0), random.random()))
    entry["last_used"] = now
    entry["uses"] = entry.get("uses", 0) + 1
    proxy = entry["url"]

    if not entry.get("fps"):
        entry["fps"] = [gen_fp(entry.get("country") or "US", DEVICE_MODE == "mobile") for _ in range(FPS_PER_PROXY)]

    idx = entry["uses"] % len(entry["fps"]) if rotate else 0
    chosen = entry["fps"][idx]
    prof = {k: v for k, v in chosen.items() if k != "name"}
    prof, tz_note = align_fp(prof, entry.get("country"))
    num = entries.index(entry) + 1
    name = f"s{num}-f{idx + 1}"
    prof["proxy"] = proxy
    prof["seed"] = random.randint(10000, 99999)
    cfg["profiles"][name] = prof
    save_config(cfg)
    tag = "rotate" if rotate else "single"
    return name, proxy, f"{tag} | proxy #{num} ({entry.get('country') or '??'}) | fp {idx + 1} | {tz_note}{note_cd}"


def build_candidates(profile, proxy, prev_profile, prev_proxy, base_profile):
    chain = [(profile, proxy)]
    if prev_proxy:
        chain.append((profile, prev_proxy))
    if prev_profile and prev_profile != profile:
        chain.append((prev_profile, prev_proxy))
    chain.append((prev_profile or base_profile, None))
    return chain


# ------------------------------------------------------------------ runner

async def run_automation(bot, chat_id, fixed_profile, target_url, max_loops):
    global ACTIVE_PAGE, ACTIVE_CONTEXT, IS_RUNNING, REAL_IP, LAST_REPORT_PATH, LAST_NET

    IS_RUNNING = True
    STOP_EVENT.clear()
    rotate = FORCE_ROTATE or max_loops is None or max_loops >= 2
    prev_profile = prev_proxy = None
    rows = []
    last_need_new = False
    started = datetime.now().isoformat(timespec="seconds")

    try:
        cfg = load_config()
        base = fixed_profile or cfg.get("default_profile", "p1")
        if base not in cfg["profiles"]:
            cfg["profiles"][base] = {"proxy": None, "seed": random.randint(10000, 99999)}
            save_config(cfg)

        saver = saver_mode(cfg)
        gap = int(cfg.get("gap_seconds", 60))
        if VERIFY_ENABLED:
            REAL_IP = await asyncio.to_thread(fetch_real_ip)

        await bot.send_message(chat_id=chat_id, text=(
            f"🚀 NEXUS v7.3 start\n"
            f"Loops: {'inf' if max_loops is None else max_loops} | rotation {'ON' if rotate else 'OFF'}\n"
            f"Gap {gap}s | saver {saver} | device {DEVICE_MODE}\n"
            f"Proxies: {len(cfg['proxies'])}\n"
            f"Real IP: {REAL_IP or 'unknown'}"))

        iteration = 0
        async with async_playwright() as p:
            while True:
                if STOP_EVENT.is_set():
                    await status(bot, chat_id, "stop kiya gaya", False)
                    break
                if max_loops is not None and iteration >= max_loops:
                    await status(bot, chat_id, f"{max_loops} loops poore", True)
                    break

                cfg = load_config()
                profile, proxy, note = choose_identity(cfg, iteration, base, rotate)
                iteration += 1
                label = f"Loop {iteration}/{'inf' if max_loops is None else max_loops}"
                context = None
                try:
                    await status(bot, chat_id, f"{label}: browser launch — {note}")
                    if last_need_new:
                        cands = [(profile, proxy), (prev_profile or base, None)]
                    else:
                        cands = build_candidates(profile, proxy, prev_profile, prev_proxy, base)
                    context, used_p, used_pr, disp, stats, persona = await launch_with_fallback(p, cands, saver)
                    ACTIVE_CONTEXT = context
                    page = context.pages[0] if context.pages else await context.new_page()
                    ACTIVE_PAGE = page
                    prev_profile, prev_proxy = used_p, used_pr
                    await status(bot, chat_id, f"{label}: browser ready, proxy {disp}", True)

                    if VERIFY_ENABLED:
                        await status(bot, chat_id, f"{label}: identity verify")
                        try:
                            vr = await verify_identity(page, persona, disp, is_direct=(used_pr is None))
                        except Exception as vexc:
                            vr = {"checks": [], "fatal": [short_err(vexc)], "warnings": [], "score": "0/0",
                                  "verdict": "FAIL", "proxy_pass": False, "fp_pass": False,
                                  "exit_ip": None, "geo": {}, "webrtc": []}
                        vr.update({"loop": iteration, "profile": used_p, "proxy": disp, "ads": 0})
                        rows.append(vr)
                        await bot.send_message(chat_id=chat_id, text=format_verify(vr, label))
                        await status(bot, chat_id, f"{label}: verify {vr['verdict']} ({vr['score']})",
                                     vr["verdict"] == "PASS")

                    if WARMUP_ENABLED:
                        await status(bot, chat_id, f"{label}: warm-up")
                        try:
                            await page.goto("https://linkvertise.com", wait_until="domcontentloaded", timeout=20000)
                            await dismiss_consent(page)
                            await human_idle(page, random.uniform(2.0, 4.0))
                        except Exception:
                            pass

                    try:
                        await execute_steps(bot, chat_id, page, target_url, label, stats, used_pr)
                    except Exception as se:
                        await send_ss(bot, chat_id, page, f"❌ ERROR {label}: {short_err(se)}")
                        stats["need_new"] = True

                    if rows:
                        rows[-1]["ads"] = stats.get("ads", 0)

                    LAST_NET = stats["net"]
                    stats.setdefault("counted", "stopped" if STOP_EVENT.is_set() else "unknown")
                    abort_n = sum(1 for e in stats["net"] if e["d"].startswith("abort"))
                    await bot.send_message(chat_id=chat_id, text=(
                        f"📊 {label} result\nCount: {stats['counted']}\n"
                        f"Ads: {stats['ads']} | abort {abort_n} | used {format_bytes(stats['proxy_bytes'])} | "
                        f"cache {format_bytes(stats['saved_bytes'])} ({stats['cache_hits']})"))

                    last_need_new = bool(stats.get("need_new"))
                    if last_need_new and not STOP_EVENT.is_set():
                        await status(bot, chat_id, f"{label}: agla loop naya IP + naya fingerprint", True)
                except Exception as ce:
                    await status(bot, chat_id, f"{label}: setup fail — {short_err(ce)}", False)
                    last_need_new = True
                finally:
                    ACTIVE_PAGE = ACTIVE_CONTEXT = None
                    if context is not None:
                        try:
                            await context.close()
                        except Exception:
                            pass

                if not STOP_EVENT.is_set() and (max_loops is None or iteration < max_loops):
                    remaining = "inf" if max_loops is None else str(max_loops - iteration)
                    if not await ask_continue(bot, chat_id, f"{iteration} done. Baaki {remaining}. Aage?"):
                        STOP_EVENT.set()
                        continue
                    if not (rows and rows[-1].get("limited")):
                        await gap_wait(bot, chat_id, gap)

        if rows:
            report = build_report(rows, target_url, REAL_IP, started)
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            LAST_REPORT_PATH = REPORT_DIR / f"report_{stamp}.txt"
            LAST_REPORT_PATH.write_text(report, encoding="utf-8")
            (REPORT_DIR / f"report_{stamp}.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
            for i in range(0, len(report), 3500):
                await bot.send_message(chat_id=chat_id, text=report[i:i + 3500])
            await bot.send_message(chat_id=chat_id, text=f"Report: {LAST_REPORT_PATH.name} (/report)")
    finally:
        ACTIVE_PAGE = ACTIVE_CONTEXT = None
        IS_RUNNING = False
        STOP_EVENT.clear()


def build_report(rows, target, real_ip, started):
    total = len(rows)
    counted = sum(1 for r in rows if "COUNTED" in (r.get("counted") or ""))
    pfail = sum(1 for r in rows if not r["proxy_pass"])
    ffail = sum(1 for r in rows if not r["fp_pass"])
    lines = ["NEXUS v7.3 REPORT", f"Target: {target}", f"Started: {started}",
             f"Finished: {datetime.now().isoformat(timespec='seconds')}",
             f"Baseline real IP: {real_ip or 'unknown'}",
             f"Loops: {total} | COUNTED: {counted} | proxy FAIL: {pfail} | fp FAIL: {ffail}", ""]
    for r in rows:
        g = r.get("geo") or {}
        lines.append(f"[Loop {r['loop']}] {r['verdict']} {r['score']} {r['profile']} "
                     f"exit={r.get('exit_ip')} geo={g.get('country')} counted={r.get('counted')} ads={r.get('ads')}")
        for n, e, a, ok in r["checks"]:
            if not ok:
                lines.append(f"    FAIL {n}: {a!r} != {e!r}")
        for w in r["warnings"]:
            lines.append(f"    WARN {w}")
        lines.append("")
    if total and counted == total:
        verdict = "SAB COUNTED."
    elif counted:
        verdict = f"PARTIAL {counted}/{total}."
    else:
        verdict = "KUCH COUNT NAHI HUA."
    lines += ["VERDICT: " + verdict, ""]
    return "\n".join(lines)


def parse_run_args(args, known):
    fixed = url = None
    loops = 1
    if len(args) >= 2:
        last = args[-1].lower()
        if last in ("infinite", "inf", "loop"):
            loops = None
            args = args[:-1]
        elif last.isdigit():
            loops = max(1, int(last))
            args = args[:-1]
    if len(args) >= 2 and args[0] in known and args[1].startswith("http"):
        fixed, url = args[0], args[1]
    elif len(args) == 1:
        url = args[0]
    elif len(args) >= 2:
        url = args[1] if args[0].startswith("http") else args[0]
    return fixed, url, loops


# ------------------------------------------------------------------ commands

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    await update.message.reply_text(
        "NEXUS v7.3\n\n"
        "/run <url> [count|infinite] | /run2 | /stop | /ss\n\n"
        "PROXY\n/addproxy <url> — probe fresh/flagged batata hai\n"
        "/proxylist | /proxycheck | /audit | /purge | /ipcool\n"
        "/rotate <n> | /revoke <n> | /resetuses\n"
        "/cooldown <min> | /countries us,gb | /probe on|off\n"
        "/rotation on|off — ek loop par bhi rotate\n\n"
        "COUNT\n/gap <sec> | /device desktop|mobile | /warmup on|off\n"
        "/verify on|off | /confirm on|off | /datasaver off|pixel|block\n"
        "/blockfonts on|off | /netlog | /logs | /report\n\n"
        "Gateway URL me customer-, -cc-, -sessid- khud lag jate hain.")


async def cmd_rotation(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global FORCE_ROTATE
    if not is_authorized(update):
        return
    if context.args and context.args[0].lower() in ("on", "off"):
        FORCE_ROTATE = context.args[0].lower() == "on"
    await update.message.reply_text(f"Rotation force: {'ON' if FORCE_ROTATE else 'OFF'}")


async def cmd_countries(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    if context.args:
        raw = [c.strip().upper()[:2] for c in context.args[0].split(",") if c.strip()]
        cc = [c for c in raw if c in COUNTRY_TZ]
        if cc:
            cfg["countries"] = [c.lower() for c in cc]
            save_config(cfg)
        elif raw:
            await update.message.reply_text("Koi valid country nahi. Jaise: /countries us,gb,de")
            return
    await update.message.reply_text("Countries: " + ", ".join(cfg.get("countries", [])))


async def cmd_probe(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global PROBE_ENABLED
    if not is_authorized(update):
        return
    if context.args and context.args[0].lower() in ("on", "off"):
        PROBE_ENABLED = context.args[0].lower() == "on"
    await update.message.reply_text(f"Probe: {'ON' if PROBE_ENABLED else 'OFF'}")


async def cmd_blockfonts(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global BLOCK_FONTS
    if not is_authorized(update):
        return
    if context.args and context.args[0].lower() in ("on", "off"):
        BLOCK_FONTS = context.args[0].lower() == "on"
    await update.message.reply_text(f"Block fonts: {'ON' if BLOCK_FONTS else 'OFF'}")


async def cmd_device(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global DEVICE_MODE
    if not is_authorized(update):
        return
    if context.args and context.args[0].lower() in ("desktop", "mobile"):
        DEVICE_MODE = context.args[0].lower()
    await update.message.reply_text(f"Device: {DEVICE_MODE}")


async def cmd_cooldown(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    if context.args and context.args[0].isdigit():
        cfg["cooldown_minutes"] = max(1, min(1440, int(context.args[0])))
        save_config(cfg)
    await update.message.reply_text(f"Cooldown: {cfg['cooldown_minutes']} min")


async def cmd_ipcool(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    cd = cfg.get("cooldown_minutes", DEFAULT_COOLDOWN) * 60
    now = time.time()
    lines = ["IP COOLDOWN"]
    ready = 0
    for i, e in enumerate(cfg["proxies"], 1):
        left = int((e.get("last_used", 0) + cd - now) // 60) + 1
        thr = e.get("throttled_until", 0) > now
        if left <= 1 and not thr:
            ready += 1
            lines.append(f"✅ {i}. ready")
        else:
            lines.append(f"⏳ {i}. {left}m{' THR' if thr else ''}")
    lines.append(f"\nready {ready}/{len(cfg['proxies'])}")
    await update.message.reply_text("\n".join(lines))


async def cmd_netlog(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if not LAST_NET:
        await update.message.reply_text("Log khaali hai.")
        return
    lines = [f"{e['s'] or '--'} {e['m']} {e['t']} {e['n']}B {e['d']} {e['u'][:110]}" for e in LAST_NET[-120:]]
    text = "\n".join(lines)
    for i in range(0, len(text), 3800):
        await update.message.reply_text(text[i:i + 3800])


async def cmd_gap(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    if context.args and context.args[0].isdigit():
        cfg["gap_seconds"] = max(10, min(900, int(context.args[0])))
        save_config(cfg)
    await update.message.reply_text(f"Gap: {cfg['gap_seconds']}s")


async def cmd_warmup(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global WARMUP_ENABLED
    if not is_authorized(update):
        return
    if context.args and context.args[0].lower() in ("on", "off"):
        WARMUP_ENABLED = context.args[0].lower() == "on"
    await update.message.reply_text(f"Warmup: {'ON' if WARMUP_ENABLED else 'OFF'}")


async def cmd_addproxy(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if not context.args:
        await update.message.reply_text("Usage: /addproxy http://user:pass@gw:7777")
        return
    cfg = load_config()
    added = []
    for u in context.args:
        _, d = parse_proxy(u)
        if d.startswith("Direct (invalid"):
            await status(context.bot, update.effective_chat.id, f"skip invalid: {u}", False)
            continue
        host = proxy_host(u) or ""
        if is_ip_literal(host) and any(proxy_host(e["url"]) == host for e in cfg["proxies"]):
            await status(context.bot, update.effective_chat.id, f"same IP pehle se: {u}", False)
            continue
        entry = await asyncio.to_thread(add_proxy_entry, cfg, u)
        added.append(entry)
    if not added:
        await update.message.reply_text("Kuch add nahi hua.")
        return
    save_config(cfg)

    if PROBE_ENABLED:
        await status(context.bot, update.effective_chat.id, f"{len(added)} proxy probe...")
        async with async_playwright() as p:
            sem = asyncio.Semaphore(5)
            res = await asyncio.gather(*[probe_proxy(p, e["url"], e.get("country"), sem) for e in added])
        for e, (kind, info) in zip(added, res):
            await status(context.bot, update.effective_chat.id,
                         f"{e.get('country') or '??'} — {kind} ({info})",
                         True if kind == "fresh" else ("warn" if kind == "unknown" else False))
            if kind == "flagged":
                e["throttled_until"] = time.time() + 3600
            if kind == "dead" and is_gateway(e["url"]):
                await status(context.bot, update.effective_chat.id,
                             "gateway dead — credentials ya prefix check karo", False)
        save_config(cfg)

    await update.message.reply_text(f"Pool: {len(cfg['proxies'])}")


async def cmd_proxylist(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    if not cfg["proxies"]:
        await update.message.reply_text("Pool khaali.")
        return
    cd = cfg.get("cooldown_minutes", DEFAULT_COOLDOWN) * 60
    now = time.time()
    lines = ["PROXY POOL"]
    for i, e in enumerate(cfg["proxies"], 1):
        left = int((e.get("last_used", 0) + cd - now) // 60) + 1
        st = "ready" if left <= 1 else f"{left}m"
        if e.get("throttled_until", 0) > now:
            st += "/THR"
        lines.append(f"{i}. {e.get('country') or '??'} | fps {len(e.get('fps', []))} | {st}\n   {e['url']}")
    await update.message.reply_text("\n".join(lines))


async def cmd_rotate(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("Usage: /rotate <n>")
        return
    i = int(context.args[0]) - 1
    cfg = load_config()
    if i < 0 or i >= len(cfg["proxies"]):
        await update.message.reply_text("Range se bahar.")
        return
    e = cfg["proxies"][i]
    cc = e.get("country") or "US"
    e["fps"] = [gen_fp(cc, DEVICE_MODE == "mobile") for _ in range(FPS_PER_PROXY)]
    e["uses"] = 0
    save_config(cfg)
    await status(context.bot, update.effective_chat.id, f"proxy #{i + 1} ({cc}) ke naye fingerprint", True)


async def cmd_revoke(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if not context.args or not context.args[0].isdigit():
        await update.message.reply_text("Usage: /revoke <n>")
        return
    i = int(context.args[0]) - 1
    cfg = load_config()
    if i < 0 or i >= len(cfg["proxies"]):
        await update.message.reply_text("Range se bahar.")
        return
    e = cfg["proxies"].pop(i)
    save_config(cfg)
    await status(context.bot, update.effective_chat.id, f"proxy #{i + 1} revoke ({e.get('country') or '??'})", True)


async def cmd_resetuses(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    for e in cfg["proxies"]:
        e["uses"] = 0
        e["last_used"] = 0
        e["throttled_until"] = 0
    save_config(cfg)
    await update.message.reply_text("Reset ho gaya.")


def check_one_proxy(url, cc=None):
    cfg_p, _ = parse_proxy(url, cc)
    if not cfg_p:
        return False, "invalid"
    hp = urlparse(cfg_p["server"])
    auth = f"{cfg_p['username']}:{cfg_p.get('password', '')}@" if cfg_p.get("username") else ""
    p_url = f"http://{auth}{hp.hostname}:{hp.port}"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": p_url, "https": p_url}))
    try:
        with opener.open("https://api.ipify.org", timeout=15) as r:
            return True, r.read().decode().strip()
    except Exception as exc:
        return False, short_err(exc)[:40]


def audit_one(url, cc=None):
    cfg_p, _ = parse_proxy(url, cc)
    if not cfg_p:
        return {"ip": None, "ip2": None, "err": "invalid"}
    hp = urlparse(cfg_p["server"])
    auth = f"{cfg_p['username']}:{cfg_p.get('password', '')}@" if cfg_p.get("username") else ""
    p_url = f"http://{auth}{hp.hostname}:{hp.port}"
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({"http": p_url, "https": p_url}))
    ips, err = [], ""
    for _ in range(2):
        try:
            with opener.open("https://api.ipify.org", timeout=15) as r:
                ips.append(r.read().decode().strip())
        except Exception as exc:
            err = short_err(exc)[:40]
    return {"ip": ips[0] if ips else None, "ip2": ips[1] if len(ips) > 1 else None, "err": err}


async def probe_proxy(p, url, cc, sem):
    async with sem:
        cfg_p, _ = parse_proxy(url, cc)
        if not cfg_p:
            return "dead", "invalid"
        browser = None
        try:
            browser = await p.chromium.launch(headless=True, proxy=cfg_p,
                                              args=["--no-sandbox", "--disable-dev-shm-usage"])
            page = await browser.new_page(viewport={"width": 1366, "height": 768})
            await page.goto(PROBE_URL, wait_until="domcontentloaded", timeout=35000)
            await asyncio.sleep(1.5)
            try:
                body = (await page.inner_text("body"))[:3000].lower()
            except Exception:
                body = ""
            if re.search(r"\d{1,3}\s*(min|:)", body) and "wait" in body:
                return "flagged", "wait screen"
            if "continue" in body or "watch" in body or "plan" in body:
                return "fresh", "plan page khula"
            return "unknown", "signal nahi"
        except Exception as exc:
            return "dead", short_err(exc)[:40]
        finally:
            if browser:
                try:
                    await browser.close()
                except Exception:
                    pass


async def cmd_audit(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    if not cfg["proxies"]:
        await update.message.reply_text("Pool khaali.")
        return
    global REAL_IP
    if REAL_IP is None:
        REAL_IP = await asyncio.to_thread(fetch_real_ip)
    await update.message.reply_text(f"{len(cfg['proxies'])} proxy audit...")
    res = await asyncio.gather(*[asyncio.to_thread(audit_one, e["url"], e.get("country")) for e in cfg["proxies"]])
    seen, lines, bad = {}, ["AUDIT"], 0
    for i, (e, r) in enumerate(zip(cfg["proxies"], res), 1):
        ip = r["ip"]
        if not ip:
            v = f"DEAD ({r['err']})"
        elif ip == REAL_IP:
            v = "NO PROXY"
        elif r["ip2"] and r["ip2"] != ip:
            v = "ROTATING (naya IP har request)"
        elif ip in seen:
            v = f"DUPLICATE of #{seen[ip]}"
        else:
            v = "OK"
        if v == "OK":
            seen[ip] = i
        else:
            bad += 1
        lines.append(f"{'✅' if v == 'OK' else '⚠️'} {i}. {ip or '-'} — {v}")
    lines.append(f"\nOK {len(res) - bad}/{len(res)}")
    text = "\n".join(lines)
    for k in range(0, len(text), 3800):
        await update.message.reply_text(text[k:k + 3800])


async def cmd_purge(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    if not cfg["proxies"]:
        await update.message.reply_text("Pool khaali.")
        return
    await update.message.reply_text("Dead check...")
    res = await asyncio.gather(*[asyncio.to_thread(audit_one, e["url"], e.get("country")) for e in cfg["proxies"]])
    keep, removed = [], 0
    for e, r in zip(cfg["proxies"], res):
        if not r["ip"]:
            removed += 1
            continue
        keep.append(e)
    cfg["proxies"] = keep
    save_config(cfg)
    await update.message.reply_text(f"{removed} dead hataye. Bacha {len(keep)}")


async def cmd_proxycheck(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    if not cfg["proxies"]:
        await update.message.reply_text("Pool khaali.")
        return
    await update.message.reply_text(f"{len(cfg['proxies'])} proxy test...")
    res = await asyncio.gather(*[asyncio.to_thread(check_one_proxy, e["url"], e.get("country")) for e in cfg["proxies"]])
    up = 0
    lines = ["PROXY HEALTH"]
    for i, (good, info) in enumerate(res, 1):
        lines.append(f"{'✅' if good else '❌'} {i}. {info}")
        if good:
            up += 1
    lines.append(f"\nUP {up}/{len(res)}")
    await update.message.reply_text("\n".join(lines))


async def cmd_check(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if IS_RUNNING:
        await update.message.reply_text("Pehle /stop.")
        return
    global REAL_IP
    cfg = load_config()
    name = context.args[0] if context.args else cfg.get("default_profile", "p1")
    pd = dict(cfg["profiles"].get(name) or {})
    if not pd.get("user_agent"):
        pd.update({k: v for k, v in gen_fp("US").items() if k != "name"})
    override = None
    if not pd.get("proxy") and cfg["proxies"]:
        override = cfg["proxies"][0]["url"]
    await update.message.reply_text(f"Check: {name}")
    if REAL_IP is None:
        REAL_IP = await asyncio.to_thread(fetch_real_ip)
    async with async_playwright() as p:
        ctx = None
        try:
            ctx, disp, _, persona = await setup_context(p, name, pd, override, "off")
            page = ctx.pages[0] if ctx.pages else await ctx.new_page()
            await update.message.reply_text(format_verify(await verify_identity(page, persona, disp, override is None), name))
        except Exception as exc:
            await update.message.reply_text(f"Fail: {short_err(exc)}")
        finally:
            if ctx is not None:
                await ctx.close()


async def cmd_verify(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global VERIFY_ENABLED
    if not is_authorized(update):
        return
    if context.args and context.args[0].lower() in ("on", "off"):
        VERIFY_ENABLED = context.args[0].lower() == "on"
    await update.message.reply_text(f"Verify: {'ON' if VERIFY_ENABLED else 'OFF'}")


async def cmd_confirm(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global CONFIRM_ENABLED
    if not is_authorized(update):
        return
    if context.args and context.args[0].lower() in ("on", "off"):
        CONFIRM_ENABLED = context.args[0].lower() == "on"
    await update.message.reply_text(f"Confirm: {'ON' if CONFIRM_ENABLED else 'OFF'}")


async def cmd_datasaver(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    arg = context.args[0].lower() if context.args else ""
    if arg in ("off", "pixel", "block"):
        cfg["data_saver"] = arg
        save_config(cfg)
    elif arg in ("on", "true"):
        cfg["data_saver"] = "pixel"
        save_config(cfg)
    await update.message.reply_text(f"Data-Saver: {saver_mode(cfg)}")


async def cmd_report(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if LAST_REPORT_PATH is None or not LAST_REPORT_PATH.exists():
        await update.message.reply_text("Report nahi hai.")
        return
    await update.message.reply_document(document=open(LAST_REPORT_PATH, "rb"))


async def cmd_cacheclear(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    n = 0
    for f in CACHE_DIR.glob("*"):
        try:
            f.unlink()
            n += 1
        except OSError:
            pass
    await update.message.reply_text(f"{n} files delete.")


async def cmd_newprofile(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if not context.args:
        await update.message.reply_text("Usage: /newprofile <name> [proxy]")
        return
    name = context.args[0]
    val = context.args[1] if len(context.args) > 1 else None
    cfg = load_config()
    fp = gen_fp("US", DEVICE_MODE == "mobile")
    fp.pop("name", None)
    cfg["profiles"][name] = {"proxy": None if (not val or val.lower() == "none") else val,
                             "seed": random.randint(10000, 99999), **fp}
    save_config(cfg)
    await update.message.reply_text(f"Bana: {name}")


async def cmd_delprofile(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if not context.args:
        await update.message.reply_text("Usage: /delprofile <name>")
        return
    name = context.args[0]
    cfg = load_config()
    if name not in cfg["profiles"]:
        await update.message.reply_text("Nahi hai.")
        return
    cfg["profiles"].pop(name)
    save_config(cfg)
    import shutil
    shutil.rmtree(PROFILES_DIR / name, ignore_errors=True)
    await update.message.reply_text(f"Deleted {name}")


async def cmd_profiles(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    cfg = load_config()
    lines = ["PROFILES"]
    for n, d in cfg["profiles"].items():
        lines.append(f"- {n} | {d.get('country') or '-'} | {d.get('proxy') or 'Direct'}")
    await update.message.reply_text("\n".join(lines))


async def cmd_proxy(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if len(context.args) < 2:
        await update.message.reply_text("Usage: /proxy <profile> <url|none>")
        return
    prof, val = context.args[0], context.args[1]
    cfg = load_config()
    if prof not in cfg["profiles"]:
        fp = gen_fp("US", DEVICE_MODE == "mobile")
        fp.pop("name", None)
        cfg["profiles"][prof] = {"seed": random.randint(10000, 99999), **fp}
    cfg["profiles"][prof]["proxy"] = None if val.lower() == "none" else val
    save_config(cfg)
    await update.message.reply_text(f"Set {prof}")


async def cmd_run(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global RUNNING_TASK
    if not is_authorized(update):
        return
    if IS_RUNNING:
        await update.message.reply_text("Chal raha hai. /stop.")
        return
    if not context.args:
        await update.message.reply_text("Usage: /run <url> [count|infinite]")
        return
    cfg = load_config()
    fixed, url, loops = parse_run_args(list(context.args), cfg["profiles"])
    if not url or not url.startswith("http"):
        await update.message.reply_text("Invalid URL.")
        return
    RUNNING_TASK = asyncio.create_task(run_automation(context.bot, update.effective_chat.id, fixed, url, loops))


async def cmd_stop(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if not IS_RUNNING:
        await update.message.reply_text("Koi loop nahi.")
        return
    STOP_EVENT.set()
    await update.message.reply_text("Stop mila.")


async def cmd_ss(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return
    if ACTIVE_PAGE is None:
        await update.message.reply_text("Browser active nahi.")
        return
    await send_ss(context.bot, update.effective_chat.id, ACTIVE_PAGE, f"Live: {ACTIVE_PAGE.url}")


AUTO_PROXY, AUTO_URL, AUTO_COUNT = range(3)


def norm_proxy(raw):
    raw = raw.strip()
    return None if raw.lower() in ("none", "direct", "off", "-") else raw


async def cmd_run2_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_authorized(update):
        return ConversationHandler.END
    if IS_RUNNING:
        await update.message.reply_text("Chal raha hai. /stop.")
        return ConversationHandler.END
    PENDING[update.effective_chat.id] = {"profile": context.args[0] if context.args else None}
    await update.message.reply_text("Proxy bhejo. Direct ke liye none. Pool ke liye 'pool'.")
    return AUTO_PROXY


async def run2_proxy(update: Update, context: ContextTypes.DEFAULT_TYPE):
    raw = update.message.text.strip()
    if raw.lower() == "pool":
        PENDING[update.effective_chat.id]["proxy"] = "__pool__"
        await update.message.reply_text("URL bhejo")
        return AUTO_URL
    proxy = norm_proxy(raw)
    if proxy is not None:
        _, d = parse_proxy(proxy)
        if d.startswith("Direct (invalid"):
            await update.message.reply_text("Parse nahi hua. Dobara ya none.")
            return AUTO_PROXY
    PENDING[update.effective_chat.id]["proxy"] = proxy
    await update.message.reply_text("URL bhejo")
    return AUTO_URL


async def run2_url(update: Update, context: ContextTypes.DEFAULT_TYPE):
    url = update.message.text.strip()
    if not url.startswith(("http://", "https://")):
        await update.message.reply_text("http(s) URL bhejo.")
        return AUTO_URL
    PENDING[update.effective_chat.id]["url"] = url
    await update.message.reply_text("Loop count ya infinite.")
    return AUTO_COUNT


async def run2_count(update: Update, context: ContextTypes.DEFAULT_TYPE):
    global RUNNING_TASK
    raw = update.message.text.strip().lower()
    if raw in ("infinite", "inf", "loop", "0"):
        loops = None
    elif raw.isdigit():
        loops = max(1, int(raw))
    else:
        await update.message.reply_text("Number ya infinite.")
        return AUTO_COUNT
    pending = PENDING.pop(update.effective_chat.id, {})
    cfg = load_config()
    proxy = pending.get("proxy")
    wanted = pending.get("profile")
    if proxy == "__pool__":
        if not cfg["proxies"]:
            await update.message.reply_text("Pool khaali — pehle /addproxy.")
            return ConversationHandler.END
        prof = cfg.get("default_profile", "p1")
        loops = loops if loops != 1 else 2
    elif wanted and wanted in cfg["profiles"]:
        cfg["profiles"][wanted]["proxy"] = proxy
        save_config(cfg)
        prof = wanted
    else:
        prof = cfg.get("default_profile", "p1")
    rotate = FORCE_ROTATE or loops is None or loops >= 2
    await update.message.reply_text(
        f"Start {prof} | loops {'inf' if loops is None else loops} | rotation {'ON' if rotate else 'OFF'}")
    RUNNING_TASK = asyncio.create_task(
        run_automation(context.bot, update.effective_chat.id, prof, pending.get("url"), loops))
    return ConversationHandler.END


async def cmd_cancel(update: Update, context: ContextTypes.DEFAULT_TYPE):
    PENDING.pop(update.effective_chat.id, None)
    await update.message.reply_text("Cancel.")
    return ConversationHandler.END


def main():
    if not BOT_TOKEN:
        raise SystemExit("TG_BOT_TOKEN missing.")
    app = Application.builder().token(BOT_TOKEN).build()
    for n, fn in (
        ("start", cmd_start), ("run", cmd_run), ("stop", cmd_stop), ("check", cmd_check),
        ("newprofile", cmd_newprofile), ("delprofile", cmd_delprofile), ("profiles", cmd_profiles),
        ("proxy", cmd_proxy), ("addproxy", cmd_addproxy), ("addoroxy", cmd_addproxy),
        ("proxylist", cmd_proxylist), ("proxycheck", cmd_proxycheck), ("audit", cmd_audit),
        ("purge", cmd_purge), ("rotate", cmd_rotate), ("revoke", cmd_revoke),
        ("resetuses", cmd_resetuses), ("ipcool", cmd_ipcool), ("cooldown", cmd_cooldown),
        ("countries", cmd_countries), ("probe", cmd_probe), ("device", cmd_device),
        ("blockfonts", cmd_blockfonts), ("netlog", cmd_netlog), ("logs", cmd_netlog),
        ("rotation", cmd_rotation), ("gap", cmd_gap), ("warmup", cmd_warmup),
        ("datasaver", cmd_datasaver), ("cacheclear", cmd_cacheclear), ("ss", cmd_ss),
        ("verify", cmd_verify), ("confirm", cmd_confirm), ("report", cmd_report),
        ("cancel", cmd_cancel),
    ):
        app.add_handler(CommandHandler(n, fn))
    app.add_handler(CallbackQueryHandler(on_callback))
    app.add_handler(ConversationHandler(
        entry_points=[CommandHandler("run2", cmd_run2_start)],
        states={AUTO_PROXY: [MessageHandler(filters.TEXT & ~filters.COMMAND, run2_proxy)],
                AUTO_URL: [MessageHandler(filters.TEXT & ~filters.COMMAND, run2_url)],
                AUTO_COUNT: [MessageHandler(filters.TEXT & ~filters.COMMAND, run2_count)]},
        fallbacks=[CommandHandler("cancel", cmd_cancel)], per_chat=True))
    print("NEXUS v7.3 live...")
    app.run_polling()


if __name__ == "__main__":
    main()
PYEOF

chmod +x "$APP_DIR/nexus_agent.py"
mkdir -p "$APP_DIR/logs"
SHARED_CFG="$APP_DIR/shared_config.json"
echo "==> ${#TOKENS[@]} token mile — har token ka apna instance (inst1..instN)"
_n=0
for _tk in "${TOKENS[@]}"; do
  _n=$((_n+1)); _idir="$APP_DIR/inst$_n"
  mkdir -p "$_idir"
  ( umask 077; printf 'TG_BOT_TOKEN=%s\nTG_CHAT_ID=%s\n' "$_tk" "$CHAT_ID" > "$_idir/.env"; chmod 600 "$_idir/.env" )
  TG_BOT_TOKEN="$_tk" TG_CHAT_ID="$CHAT_ID" \
    NEXUS_DATA_DIR="$_idir/data" NEXUS_CONFIG="$SHARED_CFG" \
    xvfb-run -a python3 "$APP_DIR/nexus_agent.py" >>"$APP_DIR/logs/inst$_n.log" 2>&1 &
  echo "  inst$_n up (pid $!) | log: logs/inst$_n.log"
done
trap 'echo; echo "==> Sab instances band"; kill 0 2>/dev/null; exit 0' INT TERM
echo "==> Ready. Ctrl-C = sab band."
while (( $(jobs -rp | wc -l) > 0 )); do wait -n 2>/dev/null || true; done
