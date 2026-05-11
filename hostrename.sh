#!/bin/bash

# 1. 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限或 sudo 运行此脚本。"
  exit 1
fi

# 获取当前主机名
OLD_HOSTNAME=$(hostname)

echo "=================================================="
echo "🖥️  主机名修改与网络配置自愈工具 (Pro 最终版)"
echo "=================================================="

# 2. 支持参数非交互运行 或 交互式询问
if [ -n "$1" ]; then
    NEW_HOSTNAME="$1"
    echo "📌 使用传入参数作为新主机名: $NEW_HOSTNAME"
else
    read -p "❓ 请输入新的主机名: " NEW_HOSTNAME
fi

# 3. 核心校验：非空、与旧主机名对比
if [ -z "$NEW_HOSTNAME" ]; then
    echo "❌ 错误: 主机名不能为空。"
    exit 1
fi

if [ "$NEW_HOSTNAME" = "$OLD_HOSTNAME" ]; then
    echo "⚠️  提示: 新主机名与当前主机名 ($OLD_HOSTNAME) 相同，无需修改。"
    exit 0
fi

# 主机名格式正则表达式验证 (RFC 1123)
if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    echo "❌ 错误: 主机名格式不合法！"
    echo "👉 规则: 长度限 1-63 个字符，只能包含字母、数字、连字符，且不能以连字符开头或结尾。"
    exit 1
fi

echo "⏳ 正在检测系统环境..."

# 4. 稳健检测系统环境 (LXC 综合判定)
IS_LXC=false
if command -v systemd-detect-virt >/dev/null 2>&1; then
    if [ "$(systemd-detect-virt)" = "lxc" ]; then
        IS_LXC=true
    fi
elif grep -qa container=lxc /proc/1/environ 2>/dev/null || \
     [ -d /dev/lxc/ ] || \
     grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then
    IS_LXC=true
fi

# 5. 修改主机名及写入忽略文件
if [ "$IS_LXC" = true ]; then
    echo "✅ 检测到当前环境为: LXC 容器"
    if hostnamectl set-hostname "$NEW_HOSTNAME" && echo "#do not f**k my hostname" > /etc/.pve-ignore.hostname; then
        echo "🔧 LXC 主机名及忽略文件配置成功。"
    else
        echo "❌ 错误: 修改 LXC 主机名或写入忽略文件失败！"
        exit 1
    fi
else
    echo "✅ 检测到当前环境为: PVE 主机 (或普通机器)"
    if hostnamectl set-hostname "$NEW_HOSTNAME"; then
        echo "🔧 主机名配置成功。"
    else
        echo "❌ 错误: 修改主机名失败！"
        exit 1
    fi
fi

# [新增优化] 尝试重启系统主机名服务，加速主机名在各子系统间的传播
echo "🔄 正在刷新 systemd-hostnamed 缓存..."
systemctl restart systemd-hostnamed 2>/dev/null || true

# 6. 更新与自愈 /etc/hosts 文件
echo "📝 正在备份并进行 /etc/hosts 文件健康度深度体检..."

# 极端情况：文件不存在时新建
touch /etc/hosts

if ! cp /etc/hosts /etc/hosts.bak; then
    echo "❌ 错误: 备份 /etc/hosts 失败，终止替换以防破坏配置。"
    exit 1
fi

# ==================== [基础网络协议全套自修复] ====================

# 1. 修复 IPv4 localhost
if ! grep -Eq "^127\.0\.0\.1[[:space:]]+localhost" /etc/hosts; then
    if [ -s /etc/hosts ]; then
        sed -i '1i 127.0.0.1\tlocalhost' /etc/hosts
    else
        echo -e "127.0.0.1\tlocalhost" > /etc/hosts
    fi
fi

# 2. 修复 IPv6 localhost
if ! grep -Eq "^::1[[:space:]]+.*localhost" /etc/hosts; then
    if grep -Eq "^127\.0\.0\.1[[:space:]]+localhost" /etc/hosts; then
        sed -i '/^127\.0\.0\.1[[:space:]]\+localhost/a ::1\t\tlocalhost ip6-localhost ip6-loopback' /etc/hosts
    else
        echo -e "::1\t\tlocalhost ip6-localhost ip6-loopback" >> /etc/hosts
    fi
fi

# 3. 修复 IPv6 组播 (放宽正则限制，避免因为制表符不同导致重复追加，使得文件“变胖”)
if ! grep -q "^ff02::1" /etc/hosts; then
    echo -e "ff02::1\t\tip6-allnodes" >> /etc/hosts
fi

if ! grep -q "^ff02::2" /etc/hosts; then
    echo -e "ff02::2\t\tip6-allrouters" >> /etc/hosts
fi

# ==================== [精准替换与去重兜底] ====================

# 使用 sed 精确匹配旧主机名进行替换
if [ -n "$OLD_HOSTNAME" ] && [ "$OLD_HOSTNAME" != "localhost" ]; then
    sed -i -E "/^(127\.|::)/ s/\b$OLD_HOSTNAME\b/$NEW_HOSTNAME/g" /etc/hosts
fi

# [新增优化] 防止多次改名残留脏记录导致 127.0.1.1 变胖或冲突
if grep -q "^127\.0\.1\.1" /etc/hosts; then
    # 如果已经存在 127.0.1.1 行，暴力覆盖其为主机名解析（洗刷以前可能留下的旧名）
    sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
else
    # 如果不存在，则兜底追加
    echo -e "127.0.1.1\t$NEW_HOSTNAME" >> /etc/hosts
fi

# 确保双栈兜底解析 (IPv6)
if ! grep -Eq "^::1[[:space:]]+.*$NEW_HOSTNAME\b" /etc/hosts; then
    echo -e "::1\t\t$NEW_HOSTNAME" >> /etc/hosts
fi

# 去除可能因为多次操作产生的一模一样的完全重复行 (最终净化)
awk '!x[$0]++' /etc/hosts > /etc/hosts.tmp && mv /etc/hosts.tmp /etc/hosts

# 7. 最终状态验证与环境级提示
CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" = "$NEW_HOSTNAME" ]; then
    echo ""
    echo "🎉 修改与系统网络环境自建修复顺利完成！"
    echo "👉 旧主机名: $OLD_HOSTNAME"
    echo "👉 新生效主机名: $CURRENT_HOSTNAME"
    
    # [新增优化] 针对 LXC 和 PVE 给出最正确的生效建议
    if [ "$IS_LXC" = true ]; then
        echo "⚠️  操作建议: LXC 容器的网络栈依赖宿主机，强烈建议您在方便时【重启此容器】以确保新主机名彻底生效！"
    else
        echo "⚠️  操作建议: 重启当前终端或重新登录 SSH，即可看到命令行提示符的更新。"
    fi
else
    echo ""
    echo "⚠️  警告: 脚本已执行完毕，但当前验证的主机名 ($CURRENT_HOSTNAME) 仍与目标不符，请检查系统配置。"
fi
