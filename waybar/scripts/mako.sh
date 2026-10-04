#!/usr/bin/env bash
count=$(makoctl list 2>/dev/null | jq -r '.data[0] | length' 2>/dev/null)
count=${count:-0}

if makoctl mode 2>/dev/null | grep -qx 'do-not-disturb'; then
  printf '{"text":"%s","alt":"dnd","class":"dnd","tooltip":"Do not disturb\\n%s notifications"}\n' "$count" "$count"
elif (( count > 0 )); then
  printf '{"text":"%s","alt":"notification","class":"unread","tooltip":"%s notifications"}\n' "$count" "$count"
else
  printf '{"text":"","alt":"none","class":"none","tooltip":"No notifications"}\n'
fi
