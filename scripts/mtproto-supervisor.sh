#!/bin/sh
set -eu

dir=/data/panel/mtproto
config=$dir/config.toml
status=$dir/status
pid=
last=

write_status() {
  mkdir -p "$dir"
  printf '%s\n' "$1" >"$status.tmp"
  mv -f "$status.tmp" "$status"
}

stop_proxy() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
  pid=
}

trap 'stop_proxy; exit 0' INT TERM

while :; do
  current=
  if [ -s "$config" ]; then
    current=$(sha256sum "$config" | cut -d' ' -f1)
  fi
  if [ "$current" != "$last" ]; then
    stop_proxy
    last=$current
    if [ -n "$current" ]; then
      /usr/local/bin/mtg run "$config" &
      pid=$!
      write_status running
    else
      write_status stopped
    fi
  fi
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null || true
    pid=
    last=
    write_status error
    sleep 3
  fi
  sleep 2
done