#!/bin/sh
# bin/wake_info.sh - 「亮屏（同上）」点开后的说明 v0.1.0
#
# KPW6 的电源键是「按一下关、再按一下开」的同一个键，
# 所以亮屏不需要单独匹配 —— 直接用熄屏那个键即可。
# 这个脚本只显示说明，不改任何配置。

CFG=/mnt/us/extensions/KindleBTH/bin/config.json

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

_s=$(sed -n 's/.*"key_open_close_sleep"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' "$CFG" 2>/dev/null | tr -d ' ')

if [ -n "$_s" ]; then
    msg "[ SAME AS SLEEP ]" "key: $_s" "no need to learn again"
else
    msg "[ NOT SET YET ]" "learn SLEEP key first" "then this works too"
fi

sleep 2
echo "亮屏与熄屏共用同一个键（按一下关、再按一下开）"
exit 0
