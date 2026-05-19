#!/usr/bin/env ash
# shellcheck shell=dash

set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 用于记录本次脚本临时安装了哪些依赖，以便最后清理
INSTALLED_DEPS=""

pkg_manager() {
    local OP="$1" PM=apk
    shift
    if [ -f /etc/gentoo-release ]; then
        PM=emerge
        case "$OP" in
        add)
            OP='-v'
            ;;
        del)
            OP='-C'
            ;;
        esac
    fi
    if [ $# -eq 0 ]; then
        echo "$PM $OP"
    else
        $PM "$OP" "$@"
    fi
}

check_distro() {
    if [ -z "$(command -v rc-service)" ]; then
        echo "No OpenRC init-system detected."
        return 1
    fi
    if [ -f /etc/alpine-release ] || [ -f /etc/gentoo-release ]; then
        return 0
    else
        return 1
    fi
}

check_if_running_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    else
        echo "error: You must run this script as root!"
        return 1
    fi
}

identify_architecture() {
    if [ "$(uname)" != 'Linux' ]; then
        echo "error: This operating system is not supported."
        return 1
    fi
    case "$(uname -m)" in
    'i386' | 'i686')
        MACHINE='32'
        ;;
    'amd64' | 'x86_64')
        MACHINE='64'
        ;;
    'armv5tel')
        MACHINE='arm32-v5'
        ;;
    'armv6l')
        MACHINE='arm32-v6'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
    'armv7' | 'armv7l')
        MACHINE='arm32-v7a'
        grep Features /proc/cpuinfo | grep -qw 'vfp' || MACHINE='arm32-v5'
        ;;
    'armv8' | 'aarch64')
        MACHINE='arm64-v8a'
        ;;
    'mips')
        MACHINE='mips32'
        ;;
    'mipsle')
        MACHINE='mips32le'
        ;;
    'mips64')
        MACHINE='mips64'
        lscpu | grep -q "Little Endian" && MACHINE='mips64le'
        ;;
    'mips64le')
        MACHINE='mips64le'
        ;;
    'ppc64')
        MACHINE='ppc64'
        ;;
    'ppc64le')
        MACHINE='ppc64le'
        ;;
    'riscv64')
        MACHINE='riscv64'
        ;;
    's390x')
        MACHINE='s390x'
        ;;
    *)
        echo "error: The architecture is not supported."
        return 1
        ;;
    esac
    if [ ! -f '/etc/os-release' ]; then
        echo "error: Don't use outdated Linux distributions."
        return 1
    fi
}

install_dependencies() {
    local deps=""
    if [ -z "$(command -v curl)" ]; then
        deps="$deps curl"
    fi
    if [ -z "$(command -v unzip)" ]; then
        deps="$deps unzip"
    fi

    if [ -n "$deps" ]; then
        if [ -n "$(command -v apk)" ] || [ -f /etc/gentoo-release ]; then
            echo "Installing required dependencies:$deps..."
            # shellcheck disable=SC2086
            pkg_manager add $deps
            INSTALLED_DEPS="$deps"
        else
            echo "error: The script does not support the package manager in this operating system."
            exit 1
        fi
    fi
}

check_update() {
    echo "Checking for Xray updates..."
    local LATEST_TAG
    LATEST_TAG=$(curl -sI -m 10 "https://github.com/XTLS/Xray-core/releases/latest" | grep -i "^location:" | awk -F"/" '{print $NF}' | tr -d '\r' || true)

    if [ -z "$LATEST_TAG" ]; then
        echo "error: Failed to fetch the latest version information from GitHub."
        return 1
    fi

    local LATEST_VER="${LATEST_TAG#v}"

    if [ -x "/usr/local/bin/xray" ]; then
        local LOCAL_VER
        LOCAL_VER=$(/usr/local/bin/xray version 2>/dev/null | head -n 1 | awk '{print $2}' || true)
        
        if [ "$LOCAL_VER" = "$LATEST_VER" ]; then
            echo "info: Xray is already up-to-date (Version: $LOCAL_VER). No update needed."
            
            # 退出前清理临时依赖（如果执行了安装的话）
            if [ -n "$INSTALLED_DEPS" ]; then
                echo "Removing temporarily installed dependencies:$INSTALLED_DEPS..."
                # shellcheck disable=SC2086
                pkg_manager del $INSTALLED_DEPS
            fi
            exit 0
        else
            echo "info: Update available! Current: $LOCAL_VER, Latest: $LATEST_VER. Updating..."
        fi
    else
        echo "info: Xray is not installed. Proceeding with installation (Version: $LATEST_VER)..."
    fi

    DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/download/${LATEST_TAG}/Xray-linux-$MACHINE.zip"
}

download_xray() {
    echo "Downloading Xray files..."
    if ! curl -f -L -H 'Cache-Control: no-cache' -o "$ZIP_FILE" "$DOWNLOAD_LINK" -#; then
        echo 'error: Download failed! Please check your network or try again.'
        exit 1
    fi

    if ! curl -f -L -H 'Cache-Control: no-cache' -o "$ZIP_FILE.dgst" "$DOWNLOAD_LINK.dgst" -#; then
        echo 'error: Download failed! Please check your network or try again.'
        exit 1
    fi
}

verification_xray() {
    CHECKSUM=$(awk -F '= ' '/256=/ {print $2}' "$ZIP_FILE.dgst")
    LOCALSUM=$(sha256sum "$ZIP_FILE" | awk '{printf $1}')
    if [ "$CHECKSUM" != "$LOCALSUM" ]; then
        echo 'error: SHA256 check failed! Please check your network or try again.'
        return 1
    fi
}

decompression() {
    unzip -q "$ZIP_FILE" -d "$TMP_DIRECTORY"
}

is_it_running() {
    XRAY_RUNNING='0'
    if [ -n "$(pgrep xray)" ]; then
        echo "Stopping running Xray service for update..."
        rc-service xray stop
        XRAY_RUNNING='1'
    fi
}

install_xray() {
    install -m 755 "${TMP_DIRECTORY}xray" "/usr/local/bin/xray"
    install -d /usr/local/share/xray/
    install -m 644 "${TMP_DIRECTORY}geoip.dat" "/usr/local/share/xray/geoip.dat"
    install -m 644 "${TMP_DIRECTORY}geosite.dat" "/usr/local/share/xray/geosite.dat"
}

install_confdir() {
    CONFDIR='0'
    if [ ! -d '/usr/local/etc/xray/' ]; then
        install -d /usr/local/etc/xray/
        # 仅生成单个干净的 config.json
        echo '{}' >"/usr/local/etc/xray/config.json"
        CONFDIR='1'
    fi
}

install_log() {
    LOG='0'
    if [ ! -d '/var/log/xray/' ]; then
        install -d -m 755 -o 0 -g 0 /var/log/xray/
        install -m 600 -o nobody -g nobody /dev/null /var/log/xray/access.log
        install -m 600 -o nobody -g nobody /dev/null /var/log/xray/error.log
        LOG='1'
    else
        chown 0:0 /var/log/xray/
        chmod 755 /var/log/xray/
        chown nobody:nobody /var/log/xray/*.log
        chmod 600 /var/log/xray/*.log
    fi
}

install_startup_service_file() {
    OPENRC='0'
    if [ ! -f '/etc/init.d/xray' ]; then
        mkdir -p "${TMP_DIRECTORY}init.d/"
        if ! curl -f -L -o "${TMP_DIRECTORY}init.d/xray" https://github.com/XTLS/Xray-install/raw/main/alpinelinux/init.d/xray -sS; then
            echo 'error: Failed to start service file download! Please check your network or try again.'
            exit 1
        fi
        install -m 755 "${TMP_DIRECTORY}init.d/xray" /etc/init.d/xray
        OPENRC='1'
    fi
}

information() {
    echo 'installed: /usr/local/bin/xray'
    echo 'installed: /usr/local/share/xray/geoip.dat'
    echo 'installed: /usr/local/share/xray/geosite.dat'
    if [ "$CONFDIR" -eq '1' ]; then
        echo 'installed: /usr/local/etc/xray/config.json'
    fi
    if [ "$LOG" -eq '1' ]; then
        echo 'installed: /var/log/xray/'
    fi
    if [ "$OPENRC" -eq '1' ]; then
        echo 'installed: /etc/init.d/xray'
    fi
    rm -r "$TMP_DIRECTORY"
    echo "removed: $TMP_DIRECTORY"

    # 自动卸载仅为本次执行临时安装的依赖
    if [ -n "$INSTALLED_DEPS" ]; then
        echo "Removing temporarily installed dependencies:$INSTALLED_DEPS..."
        # shellcheck disable=SC2086
        pkg_manager del $INSTALLED_DEPS
    fi

    # 自动处理服务启停
    if [ "$XRAY_RUNNING" -eq '1' ]; then
        echo "Restarting Xray service..."
        rc-service xray start
    else
        echo "Adding Xray to default runlevel and starting service..."
        # 如果不存在则添加到启动项
        rc-update add xray default >/dev/null 2>&1 || true
        rc-service xray start
    fi
    
    echo "info: Xray setup and update procedure complete."
}

main() {
    check_distro || return 1
    check_if_running_as_root || return 1
    identify_architecture || return 1
    install_dependencies
    check_update || return 1

    TMP_DIRECTORY="$(mktemp -d)/"
    ZIP_FILE="${TMP_DIRECTORY}Xray-linux-$MACHINE.zip"

    download_xray
    verification_xray
    decompression
    is_it_running
    install_xray
    install_confdir
    install_log
    install_startup_service_file || return 1
    information
}

main
