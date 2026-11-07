#!/bin/sh
# bin/reset_keys.sh - 恢复出厂键位 v0.1.0
#
# 用途：键位试乱了、或者想从头再学一遍时，把 config.json 恢复成 PDF 里的默认值。
# 会先备份当前配置到 config.json.bak，再重启 KindleBTH。
#
# 默认来源优先级：
#   1) profiles/原厂默认.json
#   2) 内置默认（下面这份）

DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$DIR" ] || DIR=/mnt/us/extensions/BluetoothRemote

CFG=/mnt/us/extensions/KindleBTH/bin/config.json
KBT=/mnt/us/extensions/KindleBTH
SRC="$DIR/profiles/原厂默认.json"

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

write_default() {
cat > "$CFG" <<'EOF'
{
   "key_brightness_up": [ 103, 311, 9, 309 ],
   "key_brightness_down": [ 108, 10 ],
   "key_next_page": [104, 106, 304, 306, 115, 4, 316, 312],
   "key_prev_page": [109, 105, 305, 307, 114, 3, 310],
   "key_wake": [ 1116, 1651, 3161, 308 ],
   "key_warmth_up": [16],
   "key_warmth_down": [17],
   "key_open_close_backlight" : [314],
   "key_open_close_sleep" : [],
   "key_screenshot": [116],
   "max_retry_cnt": 100,
   "when_start_no_sleep": 0,
   "mouse_wheel_1_page_or_0_brightness": 1
}
EOF
}

[ -f "$CFG" ] || { msg "[ !! ] FAILED!" "no config.json" ""; exit 1; }

msg "[ .. ] RESTORING" "default key codes" ""
cp -f "$CFG" "$CFG.bak" 2>/dev/null

if [ -f "$SRC" ]; then
    cp -f "$SRC" "$CFG" && msg "[ OK ] RESTORED" "from 原厂默认.json" "restarting service"
else
    write_default && msg "[ OK ] RESTORED" "built-in defaults" "restarting service"
fi

# 校验
_o=$(tr -cd '{' < "$CFG" | wc -c | tr -d ' ')
_c=$(tr -cd '}' < "$CFG" | wc -c | tr -d ' ')
if [ "$_o" != "$_c" ]; then
    cp -f "$CFG.bak" "$CFG"
    msg "[ !! ] FAILED!" "invalid, rolled back" ""
    exit 1
fi

killall KindleBTH >/dev/null 2>&1
sleep 1
if [ -x "$KBT/bin/start.sh" ]; then
    sh "$KBT/bin/start.sh" >/dev/null 2>&1 &
fi

sleep 2
echo "✅ 已恢复出厂键位（备份：$CFG.bak）"
exit 0
