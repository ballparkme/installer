# 1. 备份原配置文件（以防万一）
sudo cp /etc/logrotate.d/rsyslog /etc/logrotate.d/rsyslog.bak

# 2. 一键覆盖写入新的优化配置
sudo tee /etc/logrotate.d/rsyslog > /dev/null << 'EOF'
/var/log/syslog
/var/log/mail.log
/var/log/kern.log
/var/log/auth.log
/var/log/user.log
/var/log/cron.log
{
        size 20M
        rotate 1
        missingok
        notifempty
        compress
        delaycompress
        sharedscripts
        postrotate
                /usr/lib/rsyslog/rsyslog-rotate
        endscript
}
EOF

# 3. 强制立刻执行一次日志轮转，验证并清理当前空间
sudo logrotate -f /etc/logrotate.d/rsyslog

# 4. 输出完成提示
echo "✅ rsyslog 轮转配置已更新，且已执行清理！备份文件保存在 /etc/logrotate.d/rsyslog.bak"
