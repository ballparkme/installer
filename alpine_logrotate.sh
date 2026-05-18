# 1. 确保安装了 logrotate 和我们需要的 zstd 压缩工具
apk add -u logrotate zstd

# 2. 确保配置目录存在
mkdir -p /etc/logrotate.d

# 3. 将您的终极配置安全写入系统
cat << 'EOF' > /etc/logrotate.d/alpine-system
# ======================================================================
# Alpine Linux 终极系统日志轮转配置
# 特性：5MB 切割 | 留存 3 份 | Zstd -19 极限压缩 | 秒级时间戳防冲突后缀
# ======================================================================

# 1. 系统主日志 (必须平滑重载 syslog-ng)
/var/log/messages {
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
        /etc/init.d/syslog-ng reload > /dev/null 2>&1 || true
    endscript
}

# 2. 电源管理日志 (必须平滑重载 acpid)
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

# 3. OpenRC 启动日志 (静态日志，无需重载任何服务)
/var/log/rc.log {
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

# 4. 包管理器日志 (静态日志)
/var/log/apk.log {
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

# 5. 内核底层日志 (静态日志)
/var/log/dmesg {
    size 5M
    rotate 3
    missingok
    notifempty
    create 0640 root root
    
    dateext
    dateformat -%Y%m%d-%s
    
    compress
    delaycompress
    compresscmd /usr/bin/zstd
    compressext .zst
    compressoptions --rm -q -19
}

# 6. 用户登录历史 (特殊的二进制日志，需特权组)
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

# 4. 设置标准权限
chmod 644 /etc/logrotate.d/alpine-system
