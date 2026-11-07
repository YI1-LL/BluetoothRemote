#!/bin/sh
# bin/fix_conflict.sh - 修复"翻一页又翻回来"的重复键码 v0.1.0
#
# 现象：按一次翻页键，书猛地翻两下（往前一页又往回一页）。
# 原因：同一个键码同时出现在 key_next_page 和 key_prev_page（或 wake/sleep）里。
#       KindleBTH 会把两个动作都执行。
#
# 做法：以 mapping.txt（用户亲自匹配过的结果）为准，
#       把每个已匹配的码从"其它三个动作数组"里删掉。没有 mapping.txt 的记录不动。
#
# 日志: $DIR/map.log

DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$DIR" ] || DIR=/mnt/us/extensions/BluetoothRemote

CFG="/mnt/us/extensions/KindleBTH/bin/config.json"
CFGBAK="$CFG.bak"
STATE="$DIR/mapping.txt"
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

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

get_arr() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$CFG" | tr -d ' '; }

remove_code() {   # $1=key $2=code
    _cur=$(get_arr "$1")
    [ -n "$_cur" ] || return 0
    case ",$_cur," in *",$2,"*) ;; *) return 0 ;; esac
    _new=$(printf '%s' "$_cur" | awk -v c="$2" 'BEGIN{FS=","} {out=""; for(i=1;i<=NF;i++){ if($i!="" && $i!=c) out=out (out==""?"":",") $i } print out}')
    if [ -z "$_new" ]; then
        sed -i "s/\(\"$1\"[[:space:]]*:[[:space:]]*\)\[[^]]*\]/\1[]/" "$CFG"
    else
        sed -i "s/\(\"$1\"[[:space:]]*:[[:space:]]*\)\[[^]]*\]/\1[ $_new ]/" "$CFG"
    fi
    log "fix: 从 $1 删除 $2"
}

validate() {
    _o=$(tr -cd '{' < "$CFG" | wc -c | tr -d ' ')
    _c=$(tr -cd '}' < "$CFG" | wc -c | tr -d ' ')
    [ "$_o" = "$_c" ] || return 1
    grep -q '"key_next_page"' "$CFG" && grep -q '"key_prev_page"' "$CFG" || return 1
    return 0
}

[ -f "$CFG" ] || { msg "[ !! ] FAILED!" "config.json missing" ""; exit 1; }
[ -f "$STATE" ] || { msg "[ ?? ] NOTHING TO FIX" "no mapping.txt yet" ""; exit 1; }

msg "[ .. ] CHECKING" "duplicated key codes" ""

cp -f "$CFG" "$CFGBAK" 2>/dev/null
log "==== fix_conflict start ===="

# mapping.txt 内容形如：key_prev_page=115
_fixed=0
while IFS='=' read -r k c; do
    case "$k" in key_*) ;; *) continue ;; esac
    case "$c" in ''|*[!0-9]*) continue ;; esac
    [ -n "$c" ] || continue
    # 先从"自己的"数组里保证存在
    _own=$(get_arr "$k")
    case ",$_own," in
        *",$c,"*) ;;
        *) log "fix: $c 不在 $k，跳过"; continue ;;
    esac
    # 再从其它三个动作数组里删掉
    for _o in key_prev_page key_next_page key_open_close_sleep key_wake; do
        [ "$_o" = "$k" ] && continue
        _before=$(get_arr "$_o")
        remove_code "$_o" "$c"
        _after=$(get_arr "$_o")
        [ "$_before" != "$_after" ] && { _fixed=$((_fixed + 1)); echo "  - 从 $_o 移除 $c"; }
    done
done < "$STATE"

if ! validate; then
    [ -f "$CFGBAK" ] && cp -f "$CFGBAK" "$CFG"
    msg "[ !! ] FAILED!" "invalid, rolled back" ""
    log "FAILED: validate, rolled back"
    exit 1
fi

if [ "$_fixed" -eq 0 ]; then
    msg "[ OK ] NO CONFLICT" "nothing duplicated" "in 4 action keys"
    log "no conflict found"
else
    msg "[ OK ] FIXED" "removed $_fixed duplicates" "restart service to apply"
    log "fixed $_fixed duplicate code(s)"
fi

# 让改动立即生效
if [ -x /mnt/us/extensions/KindleBTH/bin/start.sh ]; then
    killall KindleBTH >/dev/null 2>&1
    sleep 1
    sh /mnt/us/extensions/KindleBTH/bin/start.sh >/dev/null 2>&1 &
fi

sleep 3
echo "✅ 冲突检查完成，处理了 $_fixed 处重复"
exit 0
