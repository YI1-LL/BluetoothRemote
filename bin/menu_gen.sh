#!/bin/sh
# bin/menu_gen.sh - BluetoothRemote 菜单生成器 v0.2.0
#
# 两个关键改动（都踩过坑）：
#   1) 原子写入：先写 menu.json.tmp 再 mv 覆盖。因为菜单项带 refresh:true，
#      动作结束 KUAL 会立刻重读 menu.json；边写边读会读到半截 JSON，
#      表现就是「点了没反应」或「直接退回主页」。
#   2) 不再用二级菜单：配置档拍平成一级项，避免嵌套 JSON 出问题。
#
# 用法: sh bin/menu_gen.sh [-q]

DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -n "$DIR" ] || DIR=/mnt/us/extensions/BluetoothRemote

MENU_FILE="$DIR/menu.json"
CFG="/mnt/us/extensions/KindleBTH/bin/config.json"
STATE="$DIR/mapping.txt"
PDIR="$DIR/profiles"
CUR="$PDIR/current.txt"

LOG="$DIR/menu_gen.log"
exec 2>>"$LOG"
echo "---- run $(date '+%Y-%m-%d %H:%M:%S') ----" >> "$LOG"
QUIET=0
[ "$1" = "-q" ] && QUIET=1

FBINK=""
for d in /var/tmp /mnt/us/libkh/bin /mnt/us/koreader /mnt/us/linkss/bin /mnt/us/linkfonts/bin; do
    [ -x "$d/fbink" ] && { FBINK="$d/fbink"; break; }
done

say() {
    [ "$QUIET" -eq 1 ] && return 0
    [ -n "$FBINK" ] || return 0
    "$FBINK" -qpm -y -5 "$1" >/dev/null 2>&1
}

json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e 's/\r/\\r/g'
}

# ---------------------------------------------------------------- 设备名
decode_u() {
    printf '%s' "$1" | awk '
    function hexval(c){ c=tolower(c); return index("0123456789abcdef", c)-1 }
    {
        s=$0; out="";
        while (match(s, /\\u[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]/)) {
            pre=substr(s,1,RSTART-1);
            h=substr(s,RSTART+2,4);
            cp=hexval(substr(h,1,1))*4096+hexval(substr(h,2,1))*256+hexval(substr(h,3,1))*16+hexval(substr(h,4,1));
            if (cp<128) ch=sprintf("%c",cp);
            else if (cp<2048) ch=sprintf("%c%c", 192+int(cp/64), 128+(cp%64));
            else ch=sprintf("%c%c%c", 224+int(cp/4096), 128+int(cp/64)%64, 128+(cp%64));
            out=out pre ch;
            s=substr(s,RSTART+RLENGTH);
        }
        print out s;
    }'
}

conf_name_by_mac() {
    [ -f /mnt/us/kindle_hid_passthrough/devices.conf ] || return 1
    [ -n "$1" ] || return 1
    grep -i "$1" /mnt/us/kindle_hid_passthrough/devices.conf 2>/dev/null \
      | grep -viE '^[[:space:]]*#' | head -n 1 \
      | awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}' \
      | sed 's/[[:space:]]*$//'
}

sys_name_by_mac() {
    [ -n "$1" ] || return 1
    for _e in /sys/class/input/event*/device/uevent; do
        [ -f "$_e" ] || continue
        _u=$(sed -n 's/^UNIQ=//p' "$_e" 2>/dev/null | tr -d '"')
        case "$_u" in
            *"$1"*) cat "$(dirname "$_e")/name" 2>/dev/null; return 0 ;;
        esac
    done
    return 1
}

bt_name() {
    _st=$(curl -s -m 2 "http://127.0.0.1:8321/status" 2>/dev/null)
    _cd=$(printf '%s' "$_st" | sed -n 's/.*"connected_device"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

    if [ -n "$_cd" ]; then
        _n=$(conf_name_by_mac "$_cd"); [ -n "$_n" ] && { printf '%s' "$_n"; return 0; }
        _n=$(sys_name_by_mac "$_cd");  [ -n "$_n" ] && { printf '%s' "$_n"; return 0; }
    fi

    _n=$(printf '%s' "$_st" | sed -n 's/.*"connected_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    _n=$(printf '%s' "$_n" | sed 's/\\u0000//g' | tr -d '\000\r\n')
    [ -n "$_n" ] && { decode_u "$_n"; return 0; }

    for _e in /sys/class/input/event*; do
        [ -e "$_e" ] || continue
        _d=$(cat "$_e/device/name" 2>/dev/null)
        case "$_d" in ''|*pwrkey*|*pt_mt*|*accel*|*hall*|*jack*) continue ;; esac
        case "$_d" in
            *Remote*|*remote*|*HID*|*hid*|*Keyboard*|*keyboard*|*手柄*|*Gamepad*|*gamepad*)
                printf '%s' "$_d"; return 0 ;;
        esac
    done

    if [ -f /mnt/us/kindle_hid_passthrough/devices.conf ]; then
        _l=$(grep -viE '^[[:space:]]*#|^[[:space:]]*$' /mnt/us/kindle_hid_passthrough/devices.conf | head -n 1)
        _d=$(printf '%s' "$_l" | awk '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF?" ":"")}')
        [ -n "$_d" ] && { printf '%s' "$_d"; return 0; }
    fi
    return 1
}

# ---------------------------------------------------------------- 状态
state_of() {
    [ -f "$STATE" ] || return 0
    sed -n "s/^$1=//p" "$STATE" 2>/dev/null | tail -n 1
}

label() {   # $1=序号 $2=中文名 $3=config key
    _c=$(state_of "$3")
    if [ -n "$_c" ]; then
        printf '[%s] %s  已匹配: %s' "$1" "$2" "$_c"
    else
        printf '[%s] %s  (点这里开始匹配)' "$1" "$2"
    fi
}

BTNAME=$(bt_name)
CURNAME=""
[ -f "$CUR" ] && CURNAME=$(cat "$CUR" 2>/dev/null | tr -d '\r\n')

L0="[0] 刷新状态"
[ -n "$BTNAME" ] && LBT="$BTNAME" || LBT="未连接蓝牙"
L1=$(label 1 "上一页" "key_prev_page")
L2=$(label 2 "下一页" "key_next_page")
L3=$(label 3 "熄屏（再按一下亮屏）" "key_open_close_sleep")
_c4=$(state_of "key_open_close_sleep")
if [ -n "$_c4" ]; then L4="[4] 亮屏（同上）$_c4"; else L4="[4] 亮屏（同上）"; fi

# ---------------------------------------------------------------- 拼 items
SEP=""
ITEMS=""

add() {   # $1=显示名 $2=action 后缀（相对 bin/）
    _n=$(json_escape "$1")
    _a=$(json_escape "sh $DIR/bin/$2")
    if [ -z "$ITEMS" ]; then
        ITEMS="        {\"name\": \"$_n\", \"action\": \"$_a\", \"exitmenu\": false, \"refresh\": true}"
    else
        ITEMS="$ITEMS,
        {\"name\": \"$_n\", \"action\": \"$_a\", \"exitmenu\": false, \"refresh\": true}"
    fi
}

# 底层驱动还没装（udev/upstart 都没有）时，把安装项顶到最前面
if [ -d /mnt/us/kindle_hid_passthrough ] \
   && [ -z "$(ls /etc/udev/rules.d/*hid* 2>/dev/null)" ] \
   && [ -z "$(ls /etc/upstart/*hid* 2>/dev/null)" ]; then
    add "[+] 安装底层驱动（首次必点）" "install_env.sh"
fi

add "$L0" "menu_gen.sh"
add "$LBT" "menu_gen.sh"
add "$L1" "map_key.sh prev"
add "$L2" "map_key.sh next"
add "$L3" "map_key.sh sleep"
add "$L4" "wake_info.sh"
add "[5] 全部完成，启动翻页服务" "start_service.sh"
add "[6] 翻页来回跳？点这里修复" "fix_conflict.sh"

# 配置档功能已下线（设备名已经直接显示在 [0] 下面，不需要再切档）
NUM=7
add "[$NUM] 查看当前键位绑定" "show_bindings.sh"
NUM=$((NUM + 1))
add "[$NUM] 恢复出厂键位（重学一遍）" "reset_keys.sh"

# ---------------------------------------------------------------- 原子写入
TMP="$MENU_FILE.tmp"
{
    printf '{\n  "items": [\n'
    printf '    {\n      "name": "蓝牙翻页器助手",\n      "items": [\n'
    printf '%s\n' "$ITEMS"
    printf '      ]\n    }\n  ]\n}\n'
} > "$TMP" 2>/dev/null

if [ -s "$TMP" ]; then
    # mv 是原子替换：KUAL 永远读不到写了一半的文件
    mv -f "$TMP" "$MENU_FILE" 2>/dev/null || cp -f "$TMP" "$MENU_FILE"
    rm -f "$TMP" 2>/dev/null
else
    rm -f "$TMP" 2>/dev/null
    echo "❌ 生成失败：$MENU_FILE 未改动"
    exit 1
fi

if grep -q '"items"' "$MENU_FILE" 2>/dev/null; then
    echo "OK menu.json $(wc -c < "$MENU_FILE" | tr -d ' ') bytes" >> "$LOG"
else
    echo "FAIL menu.json 内容异常" >> "$LOG"
fi

say "MENU UPDATED"
echo "✅ 菜单已生成：$MENU_FILE"
exit 0
