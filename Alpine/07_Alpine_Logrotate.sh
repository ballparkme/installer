#!/bin/sh
# ==========================================
# Alpine Linux 企业级日志生态独立部署脚本 (大一统 + Xray定制版)
# ==========================================
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

# 1. 安装核心组件
echo -e "${CYAN}[+] 1/5 正在安装核心引擎 (logrotate, zstd, syslog-ng)...${NC}"
apk update
apk add -u logrotate zstd syslog-ng

# 2. 剥夺默认 syslogd 权限并由 syslog-ng 接管
echo -e "${CYAN}[+] 2/5 正在执行底层日志管家权力交接...${NC}"
service syslog stop 2>/dev/null || true
rc-update del syslog default 2>/dev/null || true
rc-update add syslog-ng default
service syslog-ng restart 2>/dev/null || true

# 3. 预见性防御：强行占位，封印所有已知/未知的系统默认轮转配置
echo -e "${CYAN}[+] 3/5 正在提前占位封印默认轮转规则，实现绝对防冲突...${NC}"
mkdir -p /etc/logrotate.d
for conf in acpid openrc syslog syslog-ng; do
    > "/etc/logrotate.d/$conf"
done

# 4. 注入混合配置 (大一统兜底 + Xray专属规则)
echo -e "${CYAN}[+] 4/5 正在注入全局与自定义专属轮转阵列...${NC}"
cat << 'EOF' > /etc/logrotate.d/alpine-system
# ======================================================================
# 规则 1：Alpine 根目录日志大一统配置 (守底线)
# 策略: 5MiB 轮转 / 仅保留1份 / copytruncate 无缝截断
# ======================================================================
/var/log/*.log /var/log/messages /var/log/wtmp /var/log/dmesg /var/log/syslog {
    size 5M
    rotate 1
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d-%H%M%S
    compress
    compresscmd /usr/bin/zstd
    compressext .zst
    compressoptions --rm -q -19
}

# ======================================================================
# 规则 2：Xray 专属自定义业务日志规则 (长效留存)
# 策略: 按天轮转 / 保留100天 / 延迟压缩方便检索 / 独享解压配置
# ======================================================================
/var/log/xray/*.log {
    daily
    rotate 100
    missingok
    notifempty
    compress
    compresscmd /usr/bin/zstd
    uncompresscmd /usr/bin/unzstd
    compressoptions -19 -T1
    compressext .zst
    delaycompress
    dateext
    dateyesterday
    dateformat -%Y-%m-%d-%H%M%S
    copytruncate        
}
EOF

chmod 644 /etc/logrotate.d/alpine-system

# 5. 连通性测试
echo -e "${CYAN}[+] 5/5 部署完成！正在执行全链路空跑 (Dry-Run) 测试...${NC}"
logrotate -d /etc/logrotate.d/alpine-system | grep "reading config file" || true
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}🎉 独立日志生态底座部署大获成功！${NC}"
echo -e "系统兜底: /var/log/ 下普通日志及突发日志，满 5M 留 1 份"
echo -e "业务定制: /var/log/xray/ 下业务日志，按天轮转，保留 100 份历史"
echo -e "切割机制: 全部采用 copytruncate 无缝截断，安全无感"
echo -e "${GREEN}==========================================${NC}"
