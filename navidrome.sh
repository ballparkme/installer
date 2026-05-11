#!/bin/bash

# 0. 检查是否以 root 权限运行
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 权限 (sudo) 运行此脚本。"
  exit 1
fi

# 1. 检测系统架构
OS_ARCH=$(uname -m)
case $OS_ARCH in
    x86_64) NAVI_ARCH="amd64" ;;
    aarch64) NAVI_ARCH="arm64" ;;
    armv7l) NAVI_ARCH="armv7" ;;
    riscv64) NAVI_ARCH="riscv64" ;;
    i386|i686) NAVI_ARCH="386" ;;
    *) echo "错误: 暂不支持的架构 $OS_ARCH"; exit 1 ;;
esac

# 2. 获取 Navidrome 最新版本信息
echo "正在获取 Navidrome 最新版本信息..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/navidrome/navidrome/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')

if [ -z "$LATEST_VERSION" ]; then
    echo "错误: 无法获取最新版本，请检查网络。"
    exit 1
fi

# 3. 检查本地版本并判断是否需要更新
IS_UPDATE=0
if command -v navidrome &> /dev/null; then
    CURRENT_VERSION=$(navidrome -v 2>/dev/null | awk '{print $1}')
    if [ "$CURRENT_VERSION" == "$LATEST_VERSION" ]; then
        echo "当前已是最新版本 v${CURRENT_VERSION}，无需安装或更新，脚本退出。"
        exit 0
    else
        echo "发现新版本: v${CURRENT_VERSION} -> v${LATEST_VERSION}，准备更新..."
        IS_UPDATE=1
        echo "正在停止旧版 Navidrome 服务..."
        systemctl stop navidrome 2>/dev/null || true
    fi
else
    echo "未检测到 Navidrome，准备全新安装 v${LATEST_VERSION}..."
fi

# 4. 下载最新版本的 tar.gz 文件
FILENAME="navidrome_${LATEST_VERSION}_linux_${NAVI_ARCH}.tar.gz"
DOWNLOAD_URL="https://github.com/navidrome/navidrome/releases/download/v${LATEST_VERSION}/${FILENAME}"

echo "开始下载: $FILENAME"
curl -L -O "$DOWNLOAD_URL"

if [ ! -f "$FILENAME" ]; then
    echo "错误: 下载失败。"
    exit 1
fi

# 5. 进入安装/配置模式

# 5.1 创建系统用户 (如果不存在)
if ! id -u navidrome > /dev/null 2>&1; then
    echo "正在创建系统用户 navidrome..."
    useradd -r -s /bin/false navidrome
else
    echo "系统用户 navidrome 已存在，跳过创建。"
fi

# 5.2 从压缩包中提取二进制文件并安装
echo "正在解压并替换二进制文件到 /usr/local/bin..."
tar -xzf "$FILENAME" navidrome
install -m 755 navidrome /usr/local/bin/navidrome

# 5.3 创建数据目录并设置属主
echo "正在检查数据目录 /var/lib/navidrome..."
install -d -o navidrome -g navidrome /var/lib/navidrome

# 5.4 创建/检查配置文件 (防覆盖机制)
echo "正在检查配置文件..."
mkdir -p /etc/navidrome
if [ ! -f /etc/navidrome/navidrome.toml ]; then
    echo "正在创建基础配置文件..."
    touch /etc/navidrome/navidrome.toml
    chown -R navidrome:navidrome /etc/navidrome
else
    echo "配置文件 /etc/navidrome/navidrome.toml 已存在，跳过修改以保留自定义配置。"
fi

# 5.5 写入 systemd 服务文件 (防覆盖机制)
echo "正在检查 systemd 服务文件..."
if [ ! -f /etc/systemd/system/navidrome.service ]; then
    echo "正在创建 systemd 服务文件..."
    cat << 'EOF' > /etc/systemd/system/navidrome.service
[Unit]
Description=Navidrome Music Server and Streamer compatible with Subsonic/Airsonic
After=remote-fs.target network.target
AssertPathExists=/var/lib/navidrome

[Install]
WantedBy=multi-user.target

[Service]
User=navidrome
Group=navidrome
Type=simple
ExecStart=/usr/local/bin/navidrome --configfile "/etc/navidrome/navidrome.toml"
WorkingDirectory=/var/lib/navidrome
TimeoutStopSec=20
KillMode=process
Restart=on-failure

# See https://www.freedesktop.org/software/systemd/man/systemd.exec.html
DevicePolicy=closed
NoNewPrivileges=yes
PrivateTmp=yes
PrivateUsers=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictNamespaces=yes
RestrictRealtime=yes
SystemCallFilter=~@clock @debug @module @mount @obsolete @reboot @setuid @swap
ReadWritePaths=/var/lib/navidrome

# You can uncomment the following line if you're not using the jukebox This
# will prevent navidrome from accessing any real (physical) devices
#PrivateDevices=yes

# You can change the following line to `strict` instead of `full` if you don't
# want navidrome to be able to write anything on your filesystem outside of
# /var/lib/navidrome.
ProtectSystem=full

# You can uncomment the following line if you don't have any media in /home/*.
# This will prevent navidrome from ever reading/writing anything there.
#ProtectHome=true

# You can customize some Navidrome config options by setting environment variables here. Ex:
#Environment=ND_BASEURL="/navidrome"
EOF
else
    echo "服务文件 /etc/systemd/system/navidrome.service 已存在，跳过修改以保留自定义配置。"
fi

# 清理下载的临时文件
rm -f "$FILENAME" navidrome

# 6. 重载 systemd 并启动服务
echo "重载 systemd 守护进程..."
systemctl daemon-reload

if [ $IS_UPDATE -eq 1 ]; then
    echo "正在重启 Navidrome 服务以应用更新..."
    systemctl restart navidrome
else
    echo "正在设置 Navidrome 开机自启并立即启动服务..."
    systemctl enable --now navidrome
fi

echo "====================================================="
echo " Navidrome v${LATEST_VERSION} 安装/更新完毕！"
echo " 服务状态可以使用以下命令查看: systemctl status navidrome"
echo "====================================================="
