#!/usr/bin/env bash

MAX_LEN=35
SEPARATOR="  •  "
SCROLL_EVERY=5
PLAYERCTL_EVERY=5
CONFIG_FILE="/tmp/waybar_cava_config"

cat > "$CONFIG_FILE" << 'EOF'
[general]
framerate = 20
bars = 12

[input]
method = pulse
source = auto

[output]
method = raw
raw_target = /dev/stdout
data_format = ascii
ascii_max_range = 7
EOF

to_bars() {
  local out="" n
  local chars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)
  local colors=(
    "#6b7280" "#22c55e" "#84cc16" "#eab308"
    "#f59e0b" "#f97316" "#ef4444" "#e11d48"
  )
  IFS=';' read -ra nums <<< "$1"
  for n in "${nums[@]}"; do
    [[ -z "$n" ]] && continue
    (( n > 7 )) && n=7
    (( n < 0 )) && n=0
    out+="<span foreground='${colors[n]}'>${chars[n]}</span>"
  done
  printf '%s' "$out"
}

pango_escape() {
  local t=$1
  t=${t//&/&amp;}
  t=${t//</&lt;}
  t=${t//>/&gt;}
  printf '%s' "$t"
}

pad() {
  local t=$1
  if (( ${#t} >= MAX_LEN )); then
    printf '%s' "${t:0:MAX_LEN}"
  else
    printf '%s%*s' "$t" $((MAX_LEN - ${#t})) ""
  fi
}

scroll_i=0
scroll_tick=0
pc_tick=0
last_song=""
status=""
song=""

stdbuf -oL cava -p "$CONFIG_FILE" 2>/dev/null | while IFS= read -r line; do
  pc_tick=$((pc_tick + 1))
  if (( pc_tick >= PLAYERCTL_EVERY )); then
    pc_tick=0
    meta=$(playerctl metadata --format '{{status}}|{{artist}} - {{title}}' 2>/dev/null)
    status=${meta%%|*}
    song=${meta#*|}
  fi

  if [[ -z "$song" || "$status" == "Stopped" ]]; then
    printf '\n'
    scroll_i=0
    scroll_tick=0
    last_song=""
    continue
  fi

  if [[ "$song" != "$last_song" ]]; then
    last_song=$song
    scroll_i=0
    scroll_tick=0
  fi

  if (( ${#song} <= MAX_LEN )); then
    title=$(pad "$song")
  else
    scroll_text="${song}${SEPARATOR}${song}"
    max_offset=$(( ${#song} + ${#SEPARATOR} ))
    title=$(pad "${scroll_text:scroll_i:MAX_LEN}")
    scroll_tick=$((scroll_tick + 1))
    if (( scroll_tick >= SCROLL_EVERY )); then
      scroll_tick=0
      scroll_i=$((scroll_i + 1))
      (( scroll_i >= max_offset )) && scroll_i=0
    fi
  fi

  if [[ "$status" == "Playing" ]]; then
    printf '%s %s\n' "$(to_bars "$line")" "$title"
  else
    printf '%s\n' "$title"
  fi
done
