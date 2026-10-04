#!/usr/bin/env python3
import html, json, os, re, urllib.request

CITY = os.environ.get("CITY", "")
BASE = f"https://wttr.in/{CITY}"
HDR = {
    "User-Agent": "curl/8.4.0",
    "Accept": "text/plain",
}

ICONS = {
    "113": "󰖙", "116": "󰖕", "119": "󰖐", "122": "󰖐",
    "143": "󰖑", "176": "󰖖", "179": "󰖒", "182": "󰙿",
    "185": "󰖗", "200": "󰖓", "227": "󰖒", "230": "󰼶",
    "248": "󰖑", "260": "󰖑", "263": "󰖖", "266": "󰖖",
    "281": "󰖗", "284": "󰖗", "293": "󰖖", "296": "󰖖",
    "299": "󰖘", "302": "󰖘", "305": "󰖘", "308": "󰖘",
    "311": "󰖗", "314": "󰖗", "317": "󰙿", "320": "󰙿",
    "323": "󰖒", "326": "󰖒", "329": "󰼶", "332": "󰼶",
    "335": "󰼶", "338": "󰼶", "350": "󰖗", "353": "󰖖",
    "356": "󰖘", "359": "󰖘", "362": "󰙿", "365": "󰙿",
    "368": "󰖒", "371": "󰼶", "374": "󰖗", "377": "󰖗",
    "386": "󰙾", "389": "󰙾", "392": "󰖓", "395": "󰖓",
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
            raw, re.S | re.I,
        )
        raw = html.unescape(m.group(1) if m else "")
        raw = re.sub(r"<[^>]+>", "", raw)
    raw = re.split(r"^Location:", raw, maxsplit=1, flags=re.M)[0]
    raw = re.sub(r"\nFollow .*", "", raw, flags=re.S)
    return raw.strip()

def temp_color(t):
    """-10°C blue → 40°C red; unique color every 1°C."""
    t = float(t)
    stops = [
        (-10,  91, 155, 213),
        (0,    34, 211, 238),
        (15,   74, 222, 128),
        (25,  250, 204,  21),
        (32,  249, 115,  22),
        (40,  239,  68,  68),
    ]
    if t <= stops[0][0]:
        _, r, g, b = stops[0]
        return f"#{r:02x}{g:02x}{b:02x}"
    if t >= stops[-1][0]:
        _, r, g, b = stops[-1]
        return f"#{r:02x}{g:02x}{b:02x}"
    for (t0, r0, g0, b0), (t1, r1, g1, b1) in zip(stops, stops[1:]):
        if t0 <= t <= t1:
            u = (t - t0) / (t1 - t0)
            r = round(r0 + (r1 - r0) * u)
            g = round(g0 + (g1 - g0) * u)
            b = round(b0 + (b1 - b0) * u)
            return f"#{r:02x}{g:02x}{b:02x}"
    return "#ffffff"

text = "N/A"
tooltip = "weather unavailable"

try:
    j = json.loads(fetch(f"{BASE}?format=j1&m"))
    cur = j["current_condition"][0]
    code = str(cur["weatherCode"])
    temp = int(cur["temp_C"])
    icon = ICONS.get(code, FALLBACK)
    color = temp_color(temp)
    text = f"{icon} <span foreground='{color}'>{temp}°C</span>"
except Exception:
    pass

try:
    forecast = pango(plain_forecast(fetch(f"{BASE}?TFq&m")))
    tooltip = f"<span font_weight='bold'><tt>{forecast}</tt></span>"
except Exception:
    pass

print(json.dumps({"text": text, "tooltip": tooltip}, ensure_ascii=False))
