#!/bin/bash

# === 检查是否为 root 或 sudo 执行 ===
if [ "$EUID" -ne 0 ]; then
  # 输出红色错误信息到标准错误 (stderr)
  echo -e "\033[31m错误：权限不足！请使用 root 用户或加上 sudo 执行此脚本。\033[0m" >&2
  exit 1
fi

echo -e "\033[32m权限检查通过，开始配置自动更新...\033[0m"

# =========================================================
# 新增：配置 DPKG 默认行为（自动保留本地配置文件）
# 这将全局应用到所有的 apt/dpkg 操作中，解决配置文件冲突弹窗问题
# =========================================================
echo -e "\033[32m配置 Dpkg 默认保留本地配置文件以防更新卡死...\033[0m"
sudo tee /etc/apt/apt.conf.d/99force-confold > /dev/null <<EOF
Dpkg::Options {
    "--force-confdef";
    "--force-confold";
};
EOF

# === 安装必要组件 ===
sudo apt update
# 新增：加入 DEBIAN_FRONTEND=noninteractive 确保初始安装过程绝对静默
sudo DEBIAN_FRONTEND=noninteractive apt install unattended-upgrades needrestart -y

# === 配置系统安全自动更新 ===
sudo tee /etc/apt/apt.conf.d/20auto-upgrades > /dev/null <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

# === 配置应用系统更新 (needrestart 自动重启服务) ===
echo "\$nrconf{restart} = 'a';" | sudo tee /etc/needrestart/conf.d/99-auto-restart.conf > /dev/null

# === 配置系统更新策略 ===
# 使用 EOF 生成自定义配置文件覆盖默认设置
sudo tee /etc/apt/apt.conf.d/99unattended-upgrades-custom.conf > /dev/null <<'EOF'
// 自定义无人值守更新策略
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename}-updates";
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

// 自动重启配置
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

# === 重启服务使配置生效 ===
sudo systemctl restart unattended-upgrades.service

# === 创建两个定时器的专属配置目录 ===
sudo mkdir -p /etc/systemd/system/apt-daily.timer.d
sudo mkdir -p /etc/systemd/system/apt-daily-upgrade.timer.d

# === 直接将配置写入覆盖文件 ===
sudo tee /etc/systemd/system/apt-daily.timer.d/override.conf > /dev/null <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=5m
EOF

sudo tee /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf > /dev/null <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=5m
EOF

# === 告诉 Systemd 配置文件已更改 ===
sudo systemctl daemon-reload

# === 重启定时器使新时间进入队列 ===
sudo systemctl restart apt-daily.timer apt-daily-upgrade.timer

# === 查看确认 ===
echo -e "\033[32m配置完成！当前定时器状态如下：\033[0m"
sudo systemctl list-timers apt*
