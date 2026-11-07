#!/bin/sh
# bin/show_bindings.sh - 查看当前四个动作各绑了哪些键码 v0.1.0
#
# 目的：一眼看出谁跟谁撞了（同一码出现在两个动作里 = 必有一个不灵）。
# 结果：屏幕卡片 + /mnt/us/brh_bindings.txt（完整清单）

CFG=/mnt/us/extensions/KindleBTH/bin/config.json
OUT=/mnt/us/brh_bindings.txt
API="http://127.0.0.1:8321"

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

arr() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p" "$CFG" 2>/dev/null | tr -d ' '; }

P=$(arr key_prev_page)
N=$(arr key_next_page)
S=$(arr key_open_close_sleep)
W=$(arr key_wake)

# 统计每个码出现在几个动作里
ALL=$(printf '%s\n%s\n%s\n%s\n' "$P" "$N" "$S" "$W" | tr ',' '\n' | grep -E '^[0-9]+$' | sort -n | uniq -c)
DUP=$(printf '%s\n' "$ALL" | awk '$1>1 {print $2}' | tr '\n' ' ')

# 冲突码标星号
mark() {   # $1=数组字符串
    _o=""
    for _c in $(printf '%s' "$1" | tr ',' ' '); do
        case " $DUP " in
            *" $_c "*) _o="$_o $_c*" ;;
            *) _o="$_o $_c" ;;
        esac
    done
    printf '%s' "${_o# }"
}

{
    echo "=================================="
    echo " 当前键位绑定  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=================================="
    echo ""
    echo "  上一页 (key_prev_page)        : $(mark "$P")"
    echo "  下一页 (key_next_page)        : $(mark "$N")"
    echo "  熄屏   (key_open_close_sleep) : $(mark "$S")"
    echo "  亮屏   (key_wake)             : $(mark "$W")"
    echo ""
    if [ -n "$DUP" ]; then
        echo "  ⚠ 重复的键码（带 * 号）：$DUP"
        echo "    同一个码只能属于一个动作，重复时后绑定的那个生效。"
    else
        echo "  ✅ 四个动作之间没有重复键码"
    fi
    echo ""
    echo "  当前连接的蓝牙设备："
    _cd=$(curl -s -m 2 "$API/status" 2>/dev/null | sed -n 's/.*"connected_device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$_cd" ] && echo "    $_cd" || echo "    （未连接）"
    echo ""
    echo "  config.json 备份：$CFG.bak"
} > "$OUT" 2>&1

if [ -n "$DUP" ]; then
    msg "[ ! ] DUP KEY CODES" "$DUP" "detail: brh_bindings.txt"
else
    msg "[ OK ] NO CONFLICT" "4 actions are clean" "detail: brh_bindings.txt"
fi

echo "✅ 已生成：$OUT"
exit 0
