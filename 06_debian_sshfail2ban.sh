#!/bin/bash

# ==================================================
# 1. 检查 root 权限
# ==================================================
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m错误：请使用 root 权限运行此脚本！\033[0m"
    echo "示例: sudo bash $0"
    exit 1
fi

echo "=================================================="
echo "2. 更新软件源并安装 fail2ban, nftables 及其依赖..."
echo "=================================================="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y fail2ban nftables python3-systemd

echo -e "\n=================================================="
echo "3. 备份现有配置文件..."
echo "=================================================="
backup_file() {
    if [ -f "$1" ]; then
        local backup_name="$1.bak.$(date +%F_%H-%M-%S)"
        cp "$1" "$backup_name"
        echo "已备份: $1 → $backup_name"
    fi
}

# 执行备份
backup_file "/etc/fail2ban/jail.local"
backup_file "/etc/fail2ban/filter.d/sshd-malicious.conf"

echo -e "\n=================================================="
echo "4. 正在写入 jail 配置文件 (/etc/fail2ban/jail.local)..."
echo "=================================================="
cat << 'EOF' > /etc/fail2ban/jail.local
[sshd]
enabled  = true
backend   = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
chain     = input
ignoreip  = 127.0.0.1/8 ::1

filter   = sshd
port     = ssh
maxretry = 3
findtime = 1h
bantime  = 1w

banaction = nftables-allports
action    = %(banaction)s[name=%(__name__)s, protocol="tcp,udp", chain="input"]

mode = aggressive
bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 64w

[sshd-malicious]
enabled  = true
backend   = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
chain     = input
ignoreip  = 127.0.0.1/8 ::1

filter   = sshd-malicious
port     = ssh
maxretry = 5
findtime = 1d
bantime  = 1w

banaction = nftables-allports
action    = %(banaction)s[name=%(__name__)s, protocol="tcp,udp", chain="input"]

bantime.increment = true
bantime.factor    = 2
bantime.maxtime   = 64w
EOF

echo -e "\n=================================================="
echo "5. 正在写入过滤器配置文件 (/etc/fail2ban/filter.d/sshd-malicious.conf)..."
echo "=================================================="
cat << 'EOF' > /etc/fail2ban/filter.d/sshd-malicious.conf
[INCLUDES]
before = common.conf

[Definition]

_daemon = (?:sshd|sshd-session)
# 混合匹配主进程 sshd 和会话进程 sshd-session

failregex = 
            #^%(__prefix_line)sConnection closed by <HOST> port \d+ \[preauth\]\s*$
            # 用于防护攻击者扫描 SSH 服务 复现方式 ssh-keyscan 此规则很激进，谨慎使用 
            ^%(__prefix_line)sReceived disconnect from <HOST> port \d+:11: Bye Bye \[preauth\]\s*$
            # 客户端主动断开 (SSH协议层 Bye Bye) 
            ^%(__prefix_line)sDisconnected from authenticating user \S+ <HOST> port \d+ \[preauth\]\s*$
            ^%(__prefix_line)sConnection closed by authenticating user \S+ <HOST> port \d+ \[preauth\]\s*$
            # 用于防护攻击者尝试使用存在的用户名进行暴力尝试
            ^%(__prefix_line)sDisconnected from invalid user \S+ <HOST> port \d+ \[preauth\]\s*$
            ^%(__prefix_line)sInvalid user \S+ from <HOST> port \d+\s*$
            ^%(__prefix_line)sConnection closed by invalid user \S+ <HOST> port \d+ \[preauth\]\s*$
            # 用于防护攻击者尝试使用不存在的用户名进行暴力尝试
            ^%(__prefix_line)sTimeout before authentication for connection from <HOST> to \S+, pid = \d+\s*$
            # 用于防护攻击者连接后不进行任何操作，导致连接资源被占用 复现方式：nc HOST-IP SHH-PORT
            ^%(__prefix_line)sUnable to negotiate with <HOST> port \d+: no matching \S+ found\. Their offer: .*\s*$
            # 用于防护攻击者使用不支持的加密算法连接 SSH 服务 复现方式 ssh-keyscan
            ^%(__prefix_line)sbanner exchange: Connection from <HOST> port \d+: invalid format\s*$
            # 用于防护攻击者发送非法格式数据连接 SSH 服务 复现方式 echo "GET / HTTP/1.1" | nc <目标IP> <目标端口>
            ^%(__prefix_line)sbanner exchange: Connection from <HOST> port \d+: could not read protocol version\s*$
            # 用于防护攻击者使用错误的协议版本连接 SSH 服务 复现方式 nmap -Pn -sV --script ssh* <目标IP> -p <目标端口>
EOF

echo -e "\n=================================================="
echo "6. 检查动作文件与启动服务..."
echo "=================================================="
if [ -f "/etc/fail2ban/action.d/nftables-allports.conf" ]; then
    echo "✓ /etc/fail2ban/action.d/nftables-allports.conf 存在。"
else
    echo -e "\033[0;33m⚠ 警告: 未找到 nftables-allports.conf，fail2ban 可能不支持 nftables。\033[0m"
fi

# 确保 nftables 优先启动并设置开机自启
echo "正在启用并启动 nftables 服务..."
systemctl enable --now nftables

# 重启并设置 fail2ban 开机自启
echo "正在启用并重启 fail2ban 服务..."
systemctl restart fail2ban
systemctl enable --now fail2ban

echo -e "\n=================================================="
echo "7. 运行状态检查"
echo "=================================================="
if systemctl is-active --quiet fail2ban; then
    echo -e "\033[0;32m✓ Fail2ban 运行正常\033[0m"
    echo -e "\n你可以使用以下命令检查封禁状态："
    echo "  sudo fail2ban-client status sshd"
    echo "  sudo fail2ban-client status sshd-malicious"
else
    echo -e "\033[0;31m✗ Fail2ban 启动失败，请检查日志:\033[0m"
    echo "  sudo journalctl -u fail2ban -e --no-pager"
fi
echo "=================================================="
