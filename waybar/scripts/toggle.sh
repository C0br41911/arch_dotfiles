#!/bin/bash
STATE="/tmp/waybar_toggle_state"
[[ ! -f "$STATE" ]] && echo 1 > "$STATE"

case "$1" in
    check)
        [[ $(cat "$STATE") == 1 ]] && exit 1 || exit 0
        ;;
    toggle)
        val=$(cat "$STATE")
        echo $(( (val + 1) % 2 )) > "$STATE"
        pkill -RTMIN+1 waybar
        pkill -RTMIN+2 waybar
        pkill -RTMIN+3 waybar
        ;;
esac   
