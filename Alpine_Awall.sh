#!/bin/sh

# 遇到错误立即停止脚本
set -e

# === 1. 权限校验 ===
if [ "$(id -u)" -ne 0 ]; then
    echo "🚨 致命错误: 配置防火墙必须拥有最高权限。"
    echo "请使用 doas $0 或 sudo $0 运行此脚本！"
    exit 1
fi

# === 2. 获取 SSH 端口 ===
echo "=== 检测 sshd 有效配置端口 ==="
SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')

if [ -z "$SSH_PORT" ]; then
    echo "🚨 致命错误: 未能通过 sshd -T 获取到有效的 SSH 监听端口。"
    echo "为防止防火墙配置错误导致服务器失联，脚本已安全终止。"
    exit 1
fi
echo "-> 成功！检测到 SSH 端口为: ${SSH_PORT}"

# === 3. 安装与服务初始化配置 ===
echo "=== 安装并配置基础组件 ==="
apk update
apk add awall iptables ip6tables

# 修正：将防火墙服务加入 boot 级别，确保在网卡启动前就生效，消灭 Awall 警告
rc-update add iptables boot
rc-update add ip6tables boot

# 主动初始化空规则存档
/etc/init.d/iptables save >/dev/null 2>&1 || true
/etc/init.d/ip6tables save >/dev/null 2>&1 || true

# 启动服务
rc-service iptables start
rc-service ip6tables start

# === 4. 初始化 ===
mkdir -p /etc/awall/optional

# === 5. 写入全局强制基线 ===
echo "=== 写入全局强制基线 (/etc/awall/server.json) ==="
# 使用 'EOF'，原样写入配置文件
cat > /etc/awall/server.json << 'EOF'
{
  "description": "Default awall policy to protect Cloud server",
  "zone": {
    "internet": {
      "iface": "eth0"
    }
  },
  "policy": [
    {
      "in": "internet",
      "action": "drop"
    },
    {
      "out": "internet",
      "action": "accept"
    },
    {
      "action": "drop"
    }
  ]
}
EOF
echo "-> 全局基线写入成功。"

# === 6. 写入 SSH 放行规则 ===
echo "=== 写入 SSH 放行规则 (/etc/awall/optional/ssh.json) ==="
# 注意：这里去掉了 EOF 的引号，用来将检测到的 $SSH_PORT 变量动态解析进去
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
                "count": 3,
                "interval": 360
            }
        }
    ]
}
EOF
echo "-> SSH 放行规则写入成功。"

# === 7. 激活规则 ===
echo "=== 启用并编译 Awall 规则 ==="
# 即使之前已经 enabled 过了，加上 || true 也不会让脚本报错停止
awall enable ssh || true
awall translate

echo "================================================="
echo "✅ 所有规则已成功编译！没有任何命名和语法冲突！"
echo "即将激活防火墙。请注意查看屏幕提示："
echo "如果您的 SSH 会话没有断开，请在 10 秒内按下【回车键】确认生效！"
echo "如果 10 秒内未按回车，或者遇到意外卡死，防火墙将自动回滚以保护您的连接。"
echo "================================================="
sleep 2

# 执行最终激活，需要用户按回车确认
awall activate
