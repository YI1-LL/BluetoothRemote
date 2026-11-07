#!/bin/sh
# bin/map_key.sh - BluetoothRemote 单键匹配向导 v0.1.0
#
# 用法: sh bin/map_key.sh prev|next|sleep|wake
#
# 交互（全在屏幕上，不用终端）：
#   1. 3-2-1 倒数
#   2. "PRESS <目标> x10" + 20 秒倒计时
#   3. 用户在翻页器上连按约 10 下
#   4. 取众数（出现次数最多的码），要求 >=3 次且占比 >=50%
#   5. 追加进 KindleBTH/config.json（不覆盖已有码），备份 + 校验 + 失败回滚
#   6. 重启 KindleBTH，回菜单看状态
#
# 日志: $DIR/map.log      状态: $DIR/mapping.txt

DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$DIR" ] || DIR=/mnt/us/extensions/BluetoothRemote

HP="/mnt/us/kindle_hid_passthrough"
HPBIN="$HP/kindle-hid-passthrough"
DEVCONF="$HP/devices.conf"
API="http://127.0.0.1:8321"

KBT="/mnt/us/extensions/KindleBTH"
CFG="$KBT/bin/config.json"
CFGBAK="$CFG.bak"

LOG="$DIR/map.log"
STATE="$DIR/mapping.txt"

CAP_SEC=12          # 采集窗口
MIN_PRESS=3         # 至少按这么多次才算数
MAX_RETRY=2

FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/fonts /mnt/us/linkfonts/bin; do
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
    _l=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
    case "$_l" in ''|*[!0-9]*) return ;; esac
    [ "$_l" -gt 300 ] && { tail -n 120 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"; echo "--- log trimmed ---" >> "$LOG"; }
}

has() { command -v "$1" >/dev/null 2>&1; }

wake_screen() { lipc-set-prop com.lab126.powerd wakeUp 1 >/dev/null 2>&1; }

has_key_q() {
    _caps=$(cat "$1/device/capabilities/key" 2>/dev/null)
    [ -n "$_caps" ] || { echo unknown; return; }
    _last=$(printf '%s\n' "$_caps" | tr ' ' '\n' | tail -n 1)
    case "$_last" in
        ''|*[!0-9A-Fa-f]*) echo unknown ;;
        *) if [ $(( 0x$_last & 0x10000 )) -ne 0 ]; then echo yes; else echo no; fi ;;
    esac
}

# 按蓝牙 MAC 精确找 event 节点（uevent 里的 UNIQ 就是设备地址，可能带双引号）
find_event_by_mac() {
    _mac=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d ' :')
    [ -n "$_mac" ] || return 1
    for _u in /sys/class/input/event*/device/uevent; do
        [ -f "$_u" ] || continue
        _uniq=$(grep -i '^UNIQ=' "$_u" 2>/dev/null | cut -d= -f2- | tr -d '"\r ' | tr 'A-Z' 'a-z' | tr -d ':')
        [ -n "$_uniq" ] || continue
        case "$_uniq" in
            *"$_mac"*) basename "$(dirname "$(dirname "$_u")")"; return 0 ;;
        esac
    done
    return 1
}

# 兜底：任何"像键盘"的输入设备（KEY_Q=yes 就够，电源键/触摸屏都没有这个位）
find_event_by_keyq() {
    for e in /sys/class/input/event*; do
        [ -e "$e" ] || continue
        _n=$(cat "$e/device/name" 2>/dev/null)
        case "$_n" in *pwrkey*|*pt_mt*|*accel*|*hall*|*jack*) continue ;; esac
        [ "$(has_key_q "$e")" = yes ] && { basename "$e"; return 0; }
    done
    return 1
}

# 兜底：按名字找（含中文手柄名）
find_event_by_name() {
    for e in /sys/class/input/event*; do
        [ -e "$e" ] || continue
        _n=$(cat "$e/device/name" 2>/dev/null)
        case "$_n" in *pwrkey*|*pt_mt*|*accel*|*hall*|*jack*) continue ;; esac
        if [ "$(has_key_q "$e")" = yes ] \
           || printf '%s' "$_n" | grep -qiE 'remote|hid|keyboard|手柄|gamepad|joystick'; then
            basename "$e"; return 0
        fi
    done
    return 1
}

# 采一段事件，输出 "code count total"
capture_votes() {   # $1=event $2=秒
    _f=/tmp/brh_vote_$$.txt
    : > "$_f"

    # 采集方式（重要）：不要用 `timeout -s INT evtest`
    #   evtest 的 SIGINT 处理在"阻塞读"时可能不生效（read 被 SA_RESTART 续上），
    #   timeout 会一直等它退出 —— 表现就是脚本停在采集这步、日志里没有 round 行。
    # 改用 `timeout cat /dev/input/eventN`：cat 被 SIGTERM 杀掉后管道 EOF，
    #   od 会把已收到的数据全部 flush 出来，不会丢尾包。
    #   16 字节/事件（32 位 armv7）：sec sec usec usec type code value value
    if has cat && has od; then
        _list=$(timeout "$2" cat "/dev/input/$1" 2>/dev/null \
                | od -v -An -tu2 -w16 | awk '$5==1 && $7==1 {print $6}')
    fi

    # 兜底：evtest（只有在 cat/od 拿不到东西时才用）
    if [ -z "$_list" ] && has evtest; then
        timeout "$2" evtest "/dev/input/$1" > "$_f" 2>&1
        _list=$(sed -n 's/.*EV_KEY), code \([0-9][0-9]*\).*value 1.*/\1/p' "$_f" 2>/dev/null)
    fi

    _total=$(printf '%s\n' "$_list" | grep -cE '^[0-9]+$')
    case "$_total" in ''|*[!0-9]*) _total=0 ;; esac
    if [ "$_total" -gt 0 ]; then
        _top=$(printf '%s\n' "$_list" | grep -E '^[0-9]+$' | sort | uniq -c | sort -rn | head -n 1)
        _cnt=$(printf '%s' "$_top" | awk '{print $1}')
        _code=$(printf '%s' "$_top" | awk '{print $2}')
    else
        _cnt=0
        _code=""
    fi
    rm -f "$_f"
    printf '%s %s %s\n' "$_code" "$_cnt" "$_total"
}

merge_code() {
    _k="$1"; _c="$2"
    _cur=$(sed -n "s/.*\"$_k\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$CFG" | tr -d ' ')
    if [ -z "$_cur" ]; then
        sed -i "s/\(\"$_k\"[[:space:]]*:[[:space:]]*\)\[[[:space:]]*\]/\1[$_c]/" "$CFG"
        return $?
    fi
    case ",$_cur," in *",$_c,"*) log "merge: $_k 已含 $_c，跳过"; return 0 ;; esac
    sed -i "s/\(\"$_k\"[[:space:]]*:[[:space:]]*\[[^]]*\)\]/\1, $_c]/" "$CFG"
    return $?
}

# 从某个数组里删掉一个码（排他用：同一码不能同时属于两个动作）
remove_code() {   # $1=key $2=code
    _cur=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$CFG" | tr -d ' ')
    [ -n "$_cur" ] || return 0
    case ",$_cur," in *",$2,"*) ;; *) return 0 ;; esac
    _new=$(printf '%s' "$_cur" | awk -v c="$2" 'BEGIN{FS=","} {out=""; for(i=1;i<=NF;i++){ if($i!="" && $i!=c) out=out (out==""?"":",") $i } print out}')
    if [ -z "$_new" ]; then
        sed -i "s/\(\"$1\"[[:space:]]*:[[:space:]]*\)\[[^]]*\]/\1[]/" "$CFG"
    else
        sed -i "s/\(\"$1\"[[:space:]]*:[[:space:]]*\)\[[^]]*\]/\1[ $_new ]/" "$CFG"
    fi
    log "remove: $2 从 $1 删除（排他）"
}

validate_cfg() {
    [ -f "$CFG" ] || return 1
    _keys=$(grep -c '"key_' "$CFG" 2>/dev/null | tr -d ' ')
    [ "${_keys:-0}" -ge 10 ] || { log "validate: key 数量 $_keys"; return 1; }
    _o=$(tr -cd '{' < "$CFG" | wc -c | tr -d ' ')
    _c=$(tr -cd '}' < "$CFG" | wc -c | tr -d ' ')
    [ "$_o" = "$_c" ] || { log "validate: 花括号 $_o/$_c"; return 1; }
    grep -q '"key_next_page"[^]]*[0-9]' "$CFG" || { log "validate: next 空"; return 1; }
    grep -q '"key_prev_page"[^]]*[0-9]' "$CFG" || { log "validate: prev 空"; return 1; }
    return 0
}

set_state() {   # $1=key $2=code
    if [ -f "$STATE" ]; then
        grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null
    else
        : > "$STATE.tmp"
    fi
    echo "$1=$2" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE" 2>/dev/null
}

# ================================================================ 参数
TARGET="$1"
case "$TARGET" in
    prev)  KEY="key_prev_page";        LABEL="PREV PAGE" ;;
    next)  KEY="key_next_page";        LABEL="NEXT PAGE" ;;
    sleep) KEY="key_open_close_sleep"; LABEL="SLEEP (screen off)" ;;
    wake)  KEY="key_wake";             LABEL="WAKE (screen on)" ;;
    *)
        msg "[ !! ] BAD ARG" "use prev/next/sleep/wake" ""
        echo "用法: map_key.sh prev|next|sleep|wake"
        exit 1
        ;;
esac

log "==== map start: $TARGET -> $KEY ===="

[ -f "$CFG" ] || { msg "[ !! ] FAILED!" "KindleBTH not installed" ""; log "no config"; exit 1; }

# ================================================================ 1 停 KindleBTH
killall KindleBTH >/dev/null 2>&1
sleep 1

# ================================================================ 2 确保 daemon
if ! pgrep -f 'kindle-hid-passthrough|ld-linux-armhf' >/dev/null 2>&1; then
    msg "[ .. ] STARTING DAEMON" "please wait" ""
    cd "$HP" 2>/dev/null || { msg "[ !! ] FAILED!" "hid-passthrough missing" ""; exit 1; }
    "$HPBIN" --daemon >> /tmp/brh_daemon.log 2>&1 &
    sleep 2
fi

# 等 API（不致命）
# 契约（真机验证过）：
#   GET /status                                   -> {daemon_running, connected_device, connected_name, devices[]...}
#   GET /connect?addr=<MAC>&protocol=<ble|classic> -> {ok, error}   ← 必须带 protocol
#   GET /disconnect?addr=<MAC>
#   没有 /health，也没有 /devices 这两个端点
api_get() { curl -s -m "$2" "$API$1" 2>/dev/null; }

jget() {   # 从 stdin 的 JSON 里取第一个字符串字段
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

_i=0
API_OK=0
while [ "$_i" -lt 15 ]; do
    if [ -n "$(api_get /status 2)" ]; then API_OK=1; break; fi
    _i=$((_i + 1)); sleep 1
done
log "api_ok=$API_OK"

# ================================================================ 3 选设备：以「当前实际连着的」为准
ADDR=""
PROTO="ble"
CD=""
CDNAME=""
if [ "$API_OK" -eq 1 ]; then
    _st=$(api_get /status 3)
    CD=$(printf '%s' "$_st" | jget connected_device)
    CDNAME=$(printf '%s' "$_st" | jget connected_name | sed 's/\\u0000//g' | tr -d '\000\r\n')
fi

if [ -n "$CD" ]; then
    # 已经连着某台（不管是念珠还是手柄）——就用它，绝不去连别的
    ADDR="$CD"
    log "using CONNECTED device: $CD ($CDNAME)"
    # 协议从 devices.conf 里按 MAC 查
    if [ -f "$DEVCONF" ]; then
        _p=$(grep -i "$CD" "$DEVCONF" 2>/dev/null | awk '{print $2}' | head -n 1)
        case "$_p" in ble|classic) PROTO="$_p" ;; esac
    fi
else
    # 没连：从 devices.conf 挑一台去连
    if [ -f "$DEVCONF" ]; then
        _line=$(grep -viE '^[[:space:]]*#|^[[:space:]]*$' "$DEVCONF" | grep -iE 'remote|翻页|手柄|gamepad' | head -n 1)
        [ -n "$_line" ] || _line=$(grep -viE '^[[:space:]]*#|^[[:space:]]*$' "$DEVCONF" | head -n 1)
        ADDR=$(printf '%s' "$_line" | awk '{print $1}')
        _p=$(printf '%s' "$_line" | awk '{print $2}')
        case "$_p" in ble|classic) PROTO="$_p" ;; esac
    fi

    if [ "$API_OK" -eq 1 ] && [ -n "$ADDR" ]; then
        msg "[ .. ] CONNECTING" "remote must be ON" ""
        _r=$(api_get "/connect?addr=$ADDR&protocol=$PROTO" 25)
        log "/connect -> ${_r:-<empty>}"
        _k=0
        while [ "$_k" -lt 20 ]; do
            CD=$(api_get /status 3 | jget connected_device)
            [ -n "$CD" ] && { ADDR="$CD"; break; }
            _k=$((_k + 1)); sleep 1
        done
        log "connected_device=${CD:-<none>} (${_k}s)"
    fi
fi

# ================================================================ 4 找 event
EV=""
if [ -n "$ADDR" ]; then
    EV=$(find_event_by_mac "$ADDR")
    [ -n "$EV" ] && log "event matched by MAC ($ADDR)"
fi
if [ -z "$EV" ]; then
    EV=$(find_event_by_keyq)
    [ -n "$EV" ] && log "event matched by KEY_Q"
fi
[ -n "$EV" ] || EV=$(find_event_by_name)


if [ -z "$EV" ]; then
    msg "[ !! ] NO DEVICE" "seen: ${CDNAME:-nothing}" "connect in BT Manager"
    log "FAILED: no event node"
    exit 1
fi
log "event=$EV name=$(cat /sys/class/input/$EV/device/name 2>/dev/null)"

# ================================================================ 5 倒数 + 采集
for n in 3 2 1; do
    msg "[ READY ] $LABEL" "press $n" ""
    sleep 1
done

code=""
cnt=0
total=0
try=0
while [ "$try" -lt "$MAX_RETRY" ]; do
    try=$((try + 1))
    msg "[ PRESS $LABEL ]" "press it ~10 times" "keep pressing ${CAP_SEC}s"
    log "phase: capture start (round $try, ${CAP_SEC}s, ev=$EV)"
    _r=$(capture_votes "$EV" "$CAP_SEC")
    log "phase: capture done"
    code=$(printf '%s' "$_r" | awk '{print $1}')
    cnt=$(printf '%s' "$_r" | awk '{print $2}')
    total=$(printf '%s' "$_r" | awk '{print $3}')
    log "round$try: code=$code count=$cnt total=$total"

    [ -z "$code" ] && { msg "[ !! ] NOTHING HEARD" "try again" ""; sleep 1; continue; }

    # 要求：按够次数，且众数占比 >=50%
    _half=$((total / 2))
    if [ "$cnt" -ge "$MIN_PRESS" ] && [ "$cnt" -ge "$_half" ]; then
        break
    fi
    msg "[ ?? ] UNCLEAR" "got $cnt/$total as $code" "try again"
    sleep 1
done

if [ -z "$code" ] || [ "$cnt" -lt "$MIN_PRESS" ]; then
    msg "[ !! ] FAILED!" "no stable key" "check keyboard mode"
    sleep 2
    log "FAILED: unstable (code=$code cnt=$cnt total=$total)"
    exit 1
fi

# ================================================================ 6 写入
msg "[ .. ] SAVING" "$LABEL = $code" "($cnt/$total)"
cp -f "$CFG" "$CFGBAK" 2>/dev/null

# 先查冲突：这个码是不是已经被别的动作占用了（服务端记录，用来提示用户）
CONFLICT=""
for _k in key_prev_page key_next_page key_open_close_sleep key_wake; do
    [ "$_k" = "$KEY" ] && continue
    _cur=$(sed -n "s/.*\"$_k\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$CFG" | tr -d ' ')
    case ",$_cur," in
        *",$code,"*)
            case "$_k" in
                key_prev_page) CONFLICT="$CONFLICT prev" ;;
                key_next_page) CONFLICT="$CONFLICT next" ;;
                key_open_close_sleep) CONFLICT="$CONFLICT sleep" ;;
                key_wake) CONFLICT="$CONFLICT wake" ;;
            esac
            ;;
    esac
done
[ -n "$CONFLICT" ] && log "conflict: $code 原本属于$CONFLICT"

merge_code "$KEY" "$code"

# 排他：同一个码不能同时属于两个动作，否则「翻一页又翻回来」
for _k in key_prev_page key_next_page key_open_close_sleep key_wake; do
    [ "$_k" = "$KEY" ] && continue
    remove_code "$_k" "$code"
done

# 写完再读一遍，确认真的进数组了（不做这一步就可能"以为写了其实没写"）
_after=$(sed -n "s/.*\"$KEY\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$CFG" | tr -d ' ')
case ",$_after," in
    *",$code,"*) log "verify: $code 已在 $KEY" ;;
    *) log "verify FAILED: $code 不在 $KEY (现在是 [$_after])" ;;
esac

if ! validate_cfg; then
    [ -f "$CFGBAK" ] && cp -f "$CFGBAK" "$CFG"
    msg "[ !! ] FAILED!" "config invalid, rolled back" ""
    log "FAILED: validate, rolled back"
    exit 1
fi

set_state "$KEY" "$code"
log "SAVED $KEY += $code"

# ================================================================ 7 收尾
wake_screen
# 重新拉起 KindleBTH，让新键位立即生效
if [ -x "$KBT/bin/start.sh" ]; then
    sh "$KBT/bin/start.sh" >/dev/null 2>&1 &
else
    ( cd "$KBT/bin" 2>/dev/null && ./KindleBTH >/dev/null 2>&1 & )
fi

sh "$DIR/bin/menu_gen.sh" -q >/dev/null 2>&1

if [ -n "$CONFLICT" ]; then
    msg "[ OK ] MAPPED" "$LABEL = key $code" "took over from$CONFLICT"
else
    msg "[ OK ] MAPPED" "$LABEL = key $code" "menu will refresh"
fi
sleep 3
echo "✅ $LABEL 已匹配到键码 $code（$cnt/$total 次）"
exit 0
