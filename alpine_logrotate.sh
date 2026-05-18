#!/bin/sh
# ==========================================
# Alpine Linux 企业级日志生态独立部署脚本
# 包含：Syslog-ng 底层接管 + Zstd 极限压缩轮转阵列 + 预见性防冲突防御
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
# 核心变化：去掉了存在性判断，无条件用 0 字节文件占领这些命名空间
for conf in acpid openrc syslog syslog-ng; do
    > "/etc/logrotate.d/$conf"
done

# 4. 注入包含正确权限组(adm)与服务重载逻辑的终极配置
echo -e "${CYAN}[+] 4/5 正在注入 Zstd 极限压缩全局轮转阵列...${NC}"
cat << 'EOF' > /etc/logrotate.d/alpine-system
# ======================================================================
# Alpine Linux 终极系统日志轮转配置 (Syslog-ng 强绑定版)
# ======================================================================

# 1. Syslog-ng 核心日志群 (共享重载脚本, 权限 root adm)
/var/log/messages /var/log/auth.log /var/log/error.log /var/log/kern.log /var/log/mail.log {
    size 5M
    rotate 3
    missingok
    notifempty
    create 0640 root adm
    
    dateext
    dateformat -%Y%m%d-%s
    
    compress
    delaycompress
    compresscmd /usr/bin/zstd
    compressext .zst
    compressoptions --rm -q -19
    
    sharedscripts
    postrotate
        /etc/init.d/syslog-ng --quiet --ifstarted reload > /dev/null 2>&1 || true
    endscript
}

# 2. 电源管理日志
/var/log/acpid.log {
    size 5M
    rotate 3
    missingok
    notifempty
    create 0640 root wheel
    dateext
    dateformat -%Y%m%d-%s
    compress
    delaycompress
    compresscmd /usr/bin/zstd
    compressext .zst
    compressoptions --rm -q -19
    postrotate
        /etc/init.d/acpid --quiet --ifstarted restart || true
    endscript
}

# 3. 系统静态日志群 (无需重载任何服务)
/var/log/rc.log /var/log/apk.log /var/log/dmesg {
    size 5M
    rotate 3
    missingok
    notifempty
    create 0644 root root
    dateext
    dateformat -%Y%m%d-%s
    compress
    delaycompress
    compresscmd /usr/bin/zstd
    compressext .zst
    compressoptions --rm -q -19
}

# 4. 二进制安全审计历史 (特殊的 utmp 组)
/var/log/wtmp {
    size 5M
    rotate 3
    missingok
    notifempty
    create 0664 root utmp
    dateext
    dateformat -%Y%m%d-%s
    compress
    delaycompress
    compresscmd /usr/bin/zstd
    compressext .zst
    compressoptions --rm -q -19
}
EOF

chmod 644 /etc/logrotate.d/alpine-system

# 5. 连通性测试
echo -e "${CYAN}[+] 5/5 部署完成！正在执行全链路空跑 (Dry-Run) 测试...${NC}"
logrotate -d /etc/logrotate.d/alpine-system | grep "reading config file"
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}🎉 独立日志生态底座部署大获成功！${NC}"
echo -e "防卫等级: 最高 (已提前占位免疫未来的 apk install 冲突)"
echo -e "底层引擎: Syslog-ng 已接管全局"
echo -e "存储策略: Zstd 字典级压缩 + 秒级防冲突轮转"
echo -e "${GREEN}==========================================${NC}"
