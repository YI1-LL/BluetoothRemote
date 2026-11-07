#!/bin/sh
# bin/start_service.sh - BluetoothRemote 一键启动 v0.1.0
#
# 做完键位匹配后，用它把「守护进程 + 蓝牙连接 + KindleBTH」一起拉起来。
# 以后想用翻页器，连接蓝牙后点这一项即可。
#
# 日志: $DIR/map.log

DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$DIR" ] || DIR=/mnt/us/extensions/BluetoothRemote

HP="/mnt/us/kindle_hid_passthrough"
HPBIN="$HP/kindle-hid-passthrough"
DEVCONF="$HP/devices.conf"
API="http://127.0.0.1:8321"
KBT="/mnt/us/extensions/KindleBTH"
LOG="$DIR/map.log"

FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/linkfonts/bin; do
    [ -x "$d/fbink" ] && { FBINK="$d/fbink"; break; }
done

msg() {
    [ -n "$FBINK" ] || return 0
    "$FBINK" -qpmM -y 0 "$1
$2
$3" >/dev/null 2>&1
}

log() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

# 1) daemon
if ! pgrep -f 'kindle-hid-passthrough|ld-linux-armhf' >/dev/null 2>&1; then
    msg "[ 1/3 ] STARTING DAEMON" "please wait" ""
    cd "$HP" 2>/dev/null || { msg "[ !! ] FAILED!" "hid-passthrough missing" ""; exit 1; }
    "$HPBIN" --daemon >> /tmp/brh_daemon.log 2>&1 &
    sleep 2
    log "daemon started"
else
    log "daemon already running"
fi

# 2) 等 API 并连接
# 契约（真机验证）：GET /status、GET /connect?addr=<MAC>&protocol=<ble|classic>、GET /disconnect?addr=<MAC>
# 没有 /health、没有 /devices
api_get() { curl -s -m "$2" "$API$1" 2>/dev/null; }
jget() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1; }

_i=0
API_OK=0
while [ "$_i" -lt 15 ]; do
    if [ -n "$(api_get /status 2)" ]; then API_OK=1; break; fi
    _i=$((_i + 1)); sleep 1
done

ADDR=""
PROTO="ble"
if [ -f "$DEVCONF" ]; then
    _line=$(grep -viE '^[[:space:]]*#|^[[:space:]]*$' "$DEVCONF" | grep -iE 'remote|翻页' | head -n 1)
    [ -n "$_line" ] || _line=$(grep -viE '^[[:space:]]*#|^[[:space:]]*$' "$DEVCONF" | head -n 1)
    ADDR=$(printf '%s' "$_line" | awk '{print $1}')
    _p=$(printf '%s' "$_line" | awk '{print $2}')
    case "$_p" in ble|classic) PROTO="$_p" ;; esac
fi

CONNECTED=0
if [ "$API_OK" -eq 1 ] && [ -n "$ADDR" ]; then
    _cd=$(api_get /status 3 | jget connected_device)
    if [ -n "$_cd" ]; then
        log "already connected: $_cd"
        CONNECTED=1
    else
        msg "[ 2/3 ] CONNECTING" "remote must be ON" ""
        _r=$(api_get "/connect?addr=$ADDR&protocol=$PROTO" 25)
        log "/connect -> ${_r:-<empty>}"
        _k=0
        while [ "$_k" -lt 20 ]; do
            _cd=$(api_get /status 3 | jget connected_device)
            [ -n "$_cd" ] && { CONNECTED=1; break; }
            _k=$((_k + 1)); sleep 1
        done
        log "connected_device=${_cd:-<none>} (${_k}s)"
    fi
else
    log "api unavailable, skip connect"
fi

# 3) KindleBTH
msg "[ 3/3 ] STARTING KindleBTH" "press page key in a book" ""
if [ -x "$KBT/bin/start.sh" ]; then
    sh "$KBT/bin/start.sh" >/dev/null 2>&1 &
else
    ( cd "$KBT/bin" 2>/dev/null && ./KindleBTH >/dev/null 2>&1 & )
fi

if [ "${CONNECTED:-0}" = "1" ]; then
    msg "[ OK ] READY" "open a book and test" ""
    log "service ready, connected"
else
    msg "[ ! ] KindleBTH STARTED" "BT not connected" "use BT Manager"
    log "service started but not connected"
fi

sh "$DIR/bin/menu_gen.sh" -q >/dev/null 2>&1
echo "✅ 启动完成（连接状态: ${CONNECTED:-0}）"
exit 0
