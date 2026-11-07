# v0.4.0

首个公开版本。

## 它能做什么

在 KUAL 里点几下，把蓝牙翻页器的按键绑成「上一页 / 下一页 / 熄屏」，不需要 SSH、不需要命令行。

## 主要功能

- **按键匹配向导**：点菜单项 → 屏幕倒数 → 连按翻页器 10 下 → 自动写入 KindleBTH 配置
- **冲突排他**：同一个键码不会同时属于两个动作（解决「翻一页又翻回来」）
- **冲突提示**：学键时若该码已被别的功能占用，屏幕会明确告诉你从谁手里接管
- **绑定总览**：一键列出四个动作各绑了哪些码，重复的自动标星号
- **恢复出厂**：试乱了可以一键还原默认键位（含备份与回滚）
- **设备名显示**：菜单里直接显示当前连着的翻页器名字
- **一键启动**：拉起 HID 守护进程 + 连接设备 + 启动 KindleBTH

## 安装

1. 先装好上游组件（本插件不包含）：
   - [kindle-hid-passthrough](https://github.com/zampierilucas/kindle-hid-passthrough)（GPL-3.0）→ 放到 `Internal Storage\kindle_hid_passthrough\`
   - KindleBTH 0.0.2（作者 de1eteit）→ 放到 `Internal Storage\extensions\KindleBTH\`
2. 把本仓库的 `BluetoothRemote` 整个文件夹放进 `Internal Storage\extensions\`
3. 打开 KUAL → 蓝牙翻页器助手 → `[0] 初始化 / 刷新菜单`
4. 退出 KUAL 再进，按菜单提示逐个绑定按键

详细步骤见 [docs/安装说明.md](docs/安装说明.md)。

## 已知限制

- 只做「按键绑定 + 服务启动」，不含驱动与翻页实现
- 部分翻页器/手柄的多个按键会发出**同一个键码**，在系统层面无法区分，因此一个码只能绑一个功能
- KUAL 只在启动时读菜单；改完菜单需退出重进才能看到

## 许可

MIT。上游两个组件各自遵循其原许可，本项目不包含它们。

## 实测环境

Kindle Paperwhite 6（固件 5.18.5，已越狱 + KUAL）
