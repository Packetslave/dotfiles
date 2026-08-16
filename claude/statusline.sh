#!/usr/bin/env bash
input=$(cat)
cwd=$(echo "$input" | jq -r '.cwd')
home="$HOME"
# Abbreviate home directory as ~
short_cwd="${cwd/#$home/\~}"

model=$(echo "$input" | jq -r '.model.display_name // empty')
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
five_hr=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

status="$(whoami)@$(hostname -s):$short_cwd"
[ -n "$model" ] && status="$status | $model"
[ -n "$used_pct" ] && status="$status | ctx: $(printf '%.0f' "$used_pct")%"
[ -n "$five_hr" ] && status="$status | 5h: $(printf '%.0f' "$five_hr")%"
[ -n "$seven_day" ] && status="$status | wk: $(printf '%.0f' "$seven_day")%"

printf "%s" "$status"
