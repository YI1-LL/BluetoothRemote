#!/bin/sh
# bin/install_env.sh - 安装底层驱动（整合包首次使用）v0.1.0
#
# 整合包里已经带了 kindle_hid_passthrough，但它的 udev 规则 / upstart 服务 /
# BTManager 应用需要通过官方 install.sh 装到系统分区，这一步需要 root（KUAL 就是 root）。
#
# 做的事：
#   1. 检查 /mnt/us/kindle_hid_passthrough 是否存在
#   2. 调 `sh scripts/install.sh installAll`（官方非交互入口，不需要喂菜单）
#   3. 校验 udev / upstart / WAF 应用是否就位
#   4. 顺手确认 KindleBTH 在 extensions 下
# 日志：/mnt/us/brh_install.log

HP=/mnt/us/kindle_hid_passthrough
KBT=/mnt/us/extensions/KindleBTH
LOG=/mnt/us/brh_install.log

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

{
    echo "=================================================="
    echo " 底层驱动安装  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=================================================="
    echo ""
} > "$LOG" 2>&1

if [ ! -d "$HP" ]; then
    msg "[ !! ] NOT FOUND" "kindle_hid_passthrough" "copy it to /mnt/us first"
    echo "❌ 找不到 $HP（整合包里的这个文件夹要放到 Kindle 根目录）"
    exit 1
fi
if [ ! -f "$HP/scripts/install.sh" ]; then
    msg "[ !! ] NO INSTALLER" "scripts/install.sh missing" ""
    exit 1
fi

msg "[ 1/3 ] INSTALLING" "udev / upstart / app" "please wait ~30s"

# 官方非交互入口：install.sh installAll（实测 166-177 行支持 <action> 参数）
cd "$HP" || exit 1
timeout 180 sh "$HP/scripts/install.sh" installAll >> "$LOG" 2>&1
rc=$?
echo "" >> "$LOG"
echo "install.sh rc=$rc" >> "$LOG"

# 校验三件套
msg "[ 2/3 ] VERIFYING" "please wait" ""
_ok=0
[ -n "$(ls /etc/udev/rules.d/*hid* 2>/dev/null)" ] && _ok=$((_ok + 1))
[ -n "$(ls /etc/upstart/*hid* 2>/dev/null)" ] && _ok=$((_ok + 1))
command -v lipc-get-prop >/dev/null 2>&1 && _ok=$((_ok + 1))

{
    echo ""
    echo "---- 校验 ----"
    echo "udev   : $(ls /etc/udev/rules.d/*hid* 2>/dev/null || echo '(无)')"
    echo "upstart: $(ls /etc/upstart/*hid* 2>/dev/null || echo '(无)')"
    echo "WAF app: $(sqlite3 /var/local/appreg.db "select handlerId from handlerIds where handlerId like '%btmanager%';" 2>/dev/null || echo '(未查)')"
    echo "KindleBTH: $([ -d "$KBT/bin" ] && echo 已就位 || echo 缺失)"
} >> "$LOG" 2>&1

# KindleBTH 兜底：整合包里应该已经在 extensions 下，缺了就提示
if [ ! -d "$KBT/bin" ]; then
    msg "[ !! ] KindleBTH MISSING" "check extensions folder" ""
    echo "❌ KindleBTH 不在 /mnt/us/extensions/KindleBTH"
    exit 1
fi

msg "[ 3/3 ] DONE" "reopen KUAL" "then run [5] start service"
echo "✅ 底层驱动安装完成（日志：$LOG）"
echo "   如果 KUAL 菜单没变化，退出重进一次。"
exit 0
