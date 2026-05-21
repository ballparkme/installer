#!/bin/sh

# 1. 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "❌ 错误: 请使用 root 权限或 sudo 运行此脚本。"
  exit 1
fi

# 获取当前主机名
OLD_HOSTNAME=$(hostname)

echo "=================================================="
echo "🖥️  Alpine 主机名修改与网络配置自愈工具 (Pro 最终版)"
echo "=================================================="

# 2. 支持参数非交互运行 或 交互式询问
if [ -n "$1" ]; then
    NEW_HOSTNAME="$1"
    echo "📌 使用传入参数作为新主机名: $NEW_HOSTNAME"
else
    printf "❓ 请输入新的主机名: "
    read NEW_HOSTNAME
fi

# 清理输入两端的空格
NEW_HOSTNAME=$(echo "$NEW_HOSTNAME" | awk '{$1=$1};1')

# 3. 核心校验：非空、与旧主机名对比
if [ -z "$NEW_HOSTNAME" ]; then
    echo "❌ 错误: 主机名不能为空。"
    exit 1
fi

if [ "$NEW_HOSTNAME" = "$OLD_HOSTNAME" ]; then
    echo "⚠️  提示: 新主机名与当前主机名 ($OLD_HOSTNAME) 相同，无需修改。"
    exit 0
fi

# 主机名格式正则表达式验证 (RFC 1123，适配 BusyBox sh)
if ! echo "$NEW_HOSTNAME" | grep -Eq '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
    echo "❌ 错误: 主机名格式不合法！"
    echo "👉 规则: 长度限 1-63 个字符，只能包含字母、数字、连字符，且不能以连字符开头或结尾。"
    exit 1
fi

echo "⏳ 正在检测系统环境..."

# 4. 稳健检测系统环境 (LXC 综合判定，兼容精简环境)
IS_LXC=false
if grep -qa container=lxc /proc/1/environ 2>/dev/null || \
   [ -d /dev/lxc/ ] || \
   grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then
    IS_LXC=true
fi

# 5. 调用 Alpine 原生工具修改主机名及写入忽略文件
if [ "$IS_LXC" = "true" ]; then
    echo "✅ 检测到当前环境为: LXC 容器"
    setup-hostname "$NEW_HOSTNAME"
    
    # [修复点] 强制更新内核实时主机名，兜底 setup-hostname 的盲区
    hostname "$NEW_HOSTNAME" 2>/dev/null
    
    # PVE 环境下防止重启后主机名被宿主机覆盖
    echo "#do not f**k my hostname" > /etc/.pve-ignore.hostname
    echo "🔧 LXC 主机名及忽略文件配置成功。"
else
    echo "✅ 检测到当前环境为: 普通机器或虚拟机"
    setup-hostname "$NEW_HOSTNAME"
    
    # [修复点] 强制更新内核实时主机名，兜底 setup-hostname 的盲区
    hostname "$NEW_HOSTNAME" 2>/dev/null
    
    echo "🔧 主机名配置成功。"
fi

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
        echo "127.0.0.1	localhost" > /etc/hosts
    fi
fi

# 2. 修复 IPv6 localhost
if ! grep -Eq "^::1[[:space:]]+.*localhost" /etc/hosts; then
    if grep -Eq "^127\.0\.0\.1[[:space:]]+localhost" /etc/hosts; then
        sed -i '/^127\.0\.0\.1[[:space:]]\+localhost/a ::1\t\tlocalhost ip6-localhost ip6-loopback' /etc/hosts
    else
        echo "::1		localhost ip6-localhost ip6-loopback" >> /etc/hosts
    fi
fi

# 3. 修复 IPv6 组播 (放宽正则限制)
if ! grep -q "^ff02::1" /etc/hosts; then
    echo "ff02::1		ip6-allnodes" >> /etc/hosts
fi

if ! grep -q "^ff02::2" /etc/hosts; then
    echo "ff02::2		ip6-allrouters" >> /etc/hosts
fi

# ==================== [精准替换与去重兜底] ====================

# 使用 sed 精确匹配旧主机名进行替换 (避开 localhost)
if [ -n "$OLD_HOSTNAME" ] && [ "$OLD_HOSTNAME" != "localhost" ]; then
    sed -i -E "/^(127\.|::)/ s/\b$OLD_HOSTNAME\b/$NEW_HOSTNAME/g" /etc/hosts
fi

# 防止多次改名残留脏记录导致 127.0.1.1 变胖或冲突
if grep -q "^127\.0\.1\.1" /etc/hosts; then
    # 如果已经存在 127.0.1.1 行，暴力覆盖其为主机名解析（洗刷以前可能留下的旧名）
    sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
else
    # 如果不存在，则兜底追加
    echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
fi

# 确保双栈兜底解析 (IPv6)
if ! grep -Eq "^::1[[:space:]]+.*$NEW_HOSTNAME\b" /etc/hosts; then
    echo "::1		$NEW_HOSTNAME" >> /etc/hosts
fi

# 去除可能因为多次操作产生的一模一样的完全重复行 (最终净化)
awk '!x[$0]++' /etc/hosts > /etc/hosts.tmp && mv /etc/hosts.tmp /etc/hosts

# 7. 最终状态验证与环境级提示
CURRENT_HOSTNAME=$(hostname)
if [ "$CURRENT_HOSTNAME" = "$NEW_HOSTNAME" ]; then
    echo ""
    echo "🎉 修改与系统网络环境自愈修复顺利完成！"
    echo "👉 旧主机名: $OLD_HOSTNAME"
    echo "👉 新生效主机名: $CURRENT_HOSTNAME"
    
    if [ "$IS_LXC" = "true" ]; then
        echo "⚠️  操作建议: LXC 容器的网络栈依赖宿主机，建议您在方便时【重启此容器】以确保新主机名在所有服务中彻底生效！"
    else
        echo "⚠️  操作建议: 重启当前终端或重新登录 SSH，即可看到命令行提示符的更新。"
    fi
else
    echo ""
    echo "⚠️  警告: 脚本已执行完毕，但当前验证的主机名 ($CURRENT_HOSTNAME) 仍与目标不符，请检查系统配置。"
fi
