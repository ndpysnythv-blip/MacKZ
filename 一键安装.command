#!/usr/bin/env bash
# 双击即可运行的一键安装入口（.command 会被 Finder 直接执行）
cd "$(dirname "$0")" || exit 1
chmod +x ./install.sh 2>/dev/null || true
bash ./install.sh

echo ""
read -n 1 -s -r -p "按任意键关闭窗口…"
