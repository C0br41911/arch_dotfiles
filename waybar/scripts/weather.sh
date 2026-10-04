#!/usr/bin/env python3
import html, json, os, re, urllib.request

CITY = os.environ.get("CITY", "")
BASE = f"https://wttr.in/{CITY}"
HDR = {
    "User-Agent": "curl/8.4.0",
    "Accept": "text/plain",
}

# WWO codes → Nerd Font (md-weather)
ICONS = {
    "113": "󰖙",  # clear / sunny
    "116": "󰖕",  # partly cloudy
    "119": "󰖐",  # cloudy
    "122": "󰖐",  # overcast
    "143": "󰖑",  # mist
    "176": "󰖖",  # patchy rain
    "179": "󰖒",  # patchy snow
    "182": "󰙿",  # sleet
    "185": "󰖗",  # freezing drizzle
    "200": "󰖓",  # thunder
    "227": "󰖒",  # blowing snow
    "230": "󰼶",  # blizzard
    "248": "󰖑",  # fog
    "260": "󰖑",  # freezing fog
    "263": "󰖖",  # light drizzle
    "266": "󰖖",
    "281": "󰖗",
    "284": "󰖗",
    "293": "󰖖",  # light rain
    "296": "󰖖",
    "299": "󰖘",  # moderate rain
    "302": "󰖘",
    "305": "󰖘",  # heavy rain
    "308": "󰖘",
    "311": "󰖗",
    "314": "󰖗",
    "317": "󰙿",
    "320": "󰙿",
    "323": "󰖒",  # light snow
    "326": "󰖒",
    "329": "󰼶",
    "332": "󰼶",
    "335": "󰼶",
    "338": "󰼶",
    "350": "󰖗",  # ice pellets
    "353": "󰖖",  # rain shower
    "356": "󰖘",
    "359": "󰖘",
    "362": "󰙿",
    "365": "󰙿",
    "368": "󰖒",
    "371": "󰼶",
    "374": "󰖗",
    "377": "󰖗",
    "386": "󰙾",  # rain + thunder
    "389": "󰙾",
    "392": "󰖓",  # snow + thunder
    "395": "󰖓",
}
FALLBACK = "󰖐"

def fetch(url):
    req = urllib.request.Request(url, headers=HDR)
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read().decode("utf-8", "replace")

def pango(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def plain_forecast(raw):
    if "<html" in raw.lower() or raw.lstrip().startswith("<!"):
        m = re.search(
            r'class="term-container"[^>]*>(.*?)</div>',
            raw,
            re.S | re.I,
        )
        raw = html.unescape(m.group(1) if m else "")
        raw = re.sub(r"<[^>]+>", "", raw)
    raw = re.split(r"^Location:", raw, maxsplit=1, flags=re.M)[0]
    raw = re.sub(r"\nFollow .*", "", raw, flags=re.S)
    return raw.strip()

text = "N/A"
tooltip = "weather unavailable"

try:
    j = json.loads(fetch(f"{BASE}?format=j1&m"))
    cur = j["current_condition"][0]
    code = str(cur["weatherCode"])
    temp = cur["temp_C"]
    icon = ICONS.get(code, FALLBACK)
    text = f"{icon} {temp}°C"
except Exception:
    pass

try:
    forecast = pango(plain_forecast(fetch(f"{BASE}?TFq&m")))
    tooltip = f"<span font_weight='bold'><tt>{forecast}</tt></span>"
except Exception:
    pass

print(json.dumps({"text": text, "tooltip": tooltip}, ensure_ascii=False))
