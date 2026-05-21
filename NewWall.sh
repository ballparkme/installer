#!/bin/sh
set -e

# === 1. 权限与幂等性校验 ===
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 致命错误: 必须使用 root 权限执行此脚本 (doas/sudo)。"
    exit 1
fi

echo "=== 初始化环境与依赖 ==="
# Alpine 默认自带 BusyBox awk，此处仅安装防火墙基础组件
apk add --quiet awall iptables ip6tables

# === 2. 动态环境侦测 ===
echo "=== 检测网络环境 ==="
# 侦测默认网卡 (彻底解决 eth0 等硬编码引发的断网灾难)
WAN_IF=$(ip route | awk '/default/ {print $5; exit}')
if [ -z "$WAN_IF" ]; then
    echo "🚨 致命错误: 无法检测到默认路由接口。"
    exit 1
fi
echo "-> 成功！检测到外网接口: ${WAN_IF}"

# 侦测 SSH 端口 (解析最终生效配置，不受文件注释干扰)
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
if [ -z "$SSH_PORT" ]; then
    echo "🚨 致命错误: 无法检测到有效 SSH 端口。"
    exit 1
fi
echo "-> 成功！检测到 SSH 端口: ${SSH_PORT}"

# === 3. 安全备份机制 ===
BACKUP_DIR="/etc/awall/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
echo "=== 备份现有配置至 $BACKUP_DIR ==="
[ -f /etc/awall/server.json ] && cp /etc/awall/server.json "$BACKUP_DIR/"
[ -f /etc/awall/optional/ssh.json ] && cp /etc/awall/optional/ssh.json "$BACKUP_DIR/"
iptables-save > "$BACKUP_DIR/iptables.save" 2>/dev/null || true
ip6tables-save > "$BACKUP_DIR/ip6tables.save" 2>/dev/null || true

# === 4. 服务状态兜底 (修复 Alpine 启动顺序隐患) ===
rc-update add iptables boot >/dev/null 2>&1
rc-update add ip6tables boot >/dev/null 2>&1
# 主动生成空规则库以允许服务启动
/etc/init.d/iptables save >/dev/null 2>&1 || true
/etc/init.d/ip6tables save >/dev/null 2>&1 || true
rc-service iptables start >/dev/null 2>&1 || true
rc-service ip6tables start >/dev/null 2>&1 || true

# === 5. 生成生产级 Awall 规则 ===
mkdir -p /etc/awall/optional

echo "=== 写入全局强制基线 (处理 IPv6 SLAAC 与 ND 协议) ==="
# 修复 Schema 警告：移除了 filter 内多余的 description 字段
cat > /etc/awall/server.json << EOF
{
  "description": "Default awall policy to protect Cloud server",
  "zone": {
    "internet": {
      "iface": "${WAN_IF}"
    }
  },
  "policy": [
    { "in": "internet", "action": "drop" },
    { "out": "internet", "action": "accept" },
    { "action": "drop" }
  ],
  "filter": [
    {
      "in": "internet",
      "out": "_fw",
      "service": "ping",
      "action": "accept"
    }
  ]
}
EOF

echo "=== 写入 SSH 放行规则 (优化并发限制，防止误杀) ==="
cat > /etc/awall/optional/ssh.json << EOF
{
    "description": "Allow incoming SSH access",
    "service": {
        "custom-ssh": [ { "proto": "tcp", "port": ${SSH_PORT} } ]
    },
    "filter": [
        {
            "in": "internet",
            "out": "_fw",
            "service": "custom-ssh",
            "action": "accept",
            "conn-limit": {
                "count": 10,
                "interval": 60
            }
        }
    ]
}
EOF

# === 6. 编译 Awall 规则 ===
awall enable ssh || true
awall translate || { echo "🚨 编译失败，终止。"; exit 1; }

# === 7. 真正的安全 Watchdog (防失联回滚机制) ===
echo "================================================="
echo "⚠️  警告: 即将激活防火墙规则！"
echo "为防止配置错误导致服务器永久失联，已启动后台 Watchdog。"
echo "激活后，您有 30 秒的时间验证连接。"
echo "如果您在 30 秒内未能输入 'yes'，防火墙将自动恢复到刚才的备份状态！"
echo "================================================="
echo "按回车键开始应用规则..."
read dummy

# 启动后台独立守护进程
(
    sleep 30
    echo -e "\n\n🚨 Watchdog 触发: 未收到确认，正在执行紧急回滚..." > /dev/tty
    iptables-restore < "$BACKUP_DIR/iptables.save" 2>/dev/null
    ip6tables-restore < "$BACKUP_DIR/ip6tables.save" 2>/dev/null
    awall disable ssh 2>/dev/null || true
    rm -f /etc/iptables/rules-save
    echo "✅ 紧急回滚完成。请检查您的网络连接并修正配置。" > /dev/tty
) &
WATCHDOG_PID=$!

# 强制激活 Awall (跳过内置的不可靠等待逻辑)
awall activate -f

# 交互确认
echo ""
echo "✅ 规则已激活！如果您的终端没有卡死，请输入 'yes' 并回车以永久保存规则："
read CONFIRM

if [ "$CONFIRM" = "yes" ]; then
    # 彻底清除 Watchdog，确认规则无误
    kill $WATCHDOG_PID 2>/dev/null
    echo "🎉 确认成功！Watchdog 已解除，规则永久生效。"
else
    echo "未输入 yes。等待 Watchdog 在 30 秒倒计时结束后进行清理..."
fi
