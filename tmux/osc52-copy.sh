#!/bin/sh
# Mirror the newest tmux paste buffer to the OUTER terminal's clipboard via OSC 52.
#
# Some applications copy by running `tmux load-buffer` rather than emitting the
# escape sequence themselves -- Claude Code does this whenever $TMUX is set and
# no native clipboard tool is available, which is every SSH session. That only
# ever fills a tmux buffer, so the text never reaches the Mac. This pushes it
# the rest of the way.
#
# Invoked from the after-load-buffer hook. Writes straight to the client's tty
# rather than calling `load-buffer -w`, which would re-fire the hook forever.
set -eu

tty=$(tmux display-message -p '#{client_tty}' 2>/dev/null) || exit 0
[ -n "$tty" ] && [ -w "$tty" ] || exit 0

b64=$(tmux save-buffer - 2>/dev/null | base64 | tr -d '\n') || exit 0
[ -n "$b64" ] || exit 0

printf '\033]52;c;%s\a' "$b64" > "$tty" 2>/dev/null || exit 0
