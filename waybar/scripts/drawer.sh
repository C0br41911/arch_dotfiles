#!/bin/bash
STATE="/tmp/waybar_drawer_state"
[[ ! -f "$STATE" ]] && echo 0 > "$STATE"

case "$1" in
    icon)
        if [[ $(cat "$STATE") == 1 ]]; then
            echo "◀"
        else
            echo "▶"
        fi
        ;;
    toggle)
        val=$(cat "$STATE")
        echo $(( (val + 1) % 2 )) > "$STATE"
        pkill -RTMIN+1 waybar
        ;;
esac   
