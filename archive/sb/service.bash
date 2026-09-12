# 创建服务文件（支持 Systemd 和 OpenRC）
create_service_files(){
    if [[ "$RELEASE" == "alpine" ]]; then
        local service_file="/etc/init.d/sing-box"
        if [[ ! -f "$service_file" ]]; then
            info "正在创建 OpenRC 服务文件..."
            cat > "$service_file" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Service"
command="$SINGBOX_BIN"
command_args="run -c $SINGBOX_CONF_PATH"
command_background="yes"
pidfile="/run/sing-box.pid"

depend() {
    need net
    after firewall
}
EOF
            chmod +x "$service_file"
            rc-update add sing-box default
            info "OpenRC 服务文件已创建并启用。"
        else
            info "OpenRC 服务文件已存在，跳过创建。"
        fi
    else
        local service_file="/etc/systemd/system/sing-box.service"
        if [[ ! -f "$service_file" ]]; then
            info "正在创建 Systemd 服务文件..."
            cat > "$service_file" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$SINGBOX_BIN run -c $SINGBOX_CONF_PATH
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable sing-box
            info "Systemd 服务文件已创建并启用。"
        else
            info "Systemd 服务文件已存在，跳过创建。"
        fi
    fi
}

# 重启 Sing-box 服务（含配置验证和格式化）
restart_singbox(){
    info "正在验证和格式化配置文件..."

    # 格式化配置文件
    "$SINGBOX_BIN" format -w -c "$SINGBOX_CONF_PATH"
    local format_result=$?

    if [[ $format_result -eq 0 ]]; then
        info "配置文件已格式化。"
    else
        warn "配置文件格式化失败，可能存在语法错误。"
    fi

    # 验证配置文件
    "$SINGBOX_BIN" check -c "$SINGBOX_CONF_PATH"
    local check_result=$?

    if [[ $check_result -eq 0 ]]; then
        info "配置文件验证通过。"
    else
        err "配置文件验证失败，请检查配置！"
        return 1
    fi

    info "正在重启 Sing-box 服务..."
    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service sing-box restart || rc-service sing-box start
    else
        systemctl restart sing-box
    fi
    info "Sing-box 已重启。"
}

# 下载并安装 Sing-box 二进制文件
install_singbox(){
    info "正在安装 Sing-box (手动二进制方式)..."

    rm -rf sing-box.tar.gz sing-box-*/

    LATEST_VER=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
    if [[ -z "$LATEST_VER" ]]; then
        warn "获取最新版本失败，使用硬编码的备用版本。"
        LATEST_VER="1.14.0"
    fi

    # 如果已安装，则按版本判断是否需要更新（保留现有配置）
    local was_installed=0
    local current_ver=""
    if [[ -x "$SINGBOX_BIN" ]]; then
        was_installed=1
        current_ver=$(sb_get_core_version)
        if [[ -n "$current_ver" && "$current_ver" == "$LATEST_VER" ]]; then
            info "检测到 Sing-box 已是最新版 v${current_ver}，跳过更新。"
            mkdir -p "$SINGBOX_CONF_DIR"
            if [[ ! -f "$SINGBOX_CONF_PATH" ]]; then
                echo '{"log": {"level": "info", "timestamp": true}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]}' > "$SINGBOX_CONF_PATH"
            fi
            create_service_files
            return 0
        fi
        if [[ -n "$current_ver" ]]; then
            info "检测到已安装 Sing-box v${current_ver}，将更新到 v${LATEST_VER}..."
        else
            info "检测到已安装 Sing-box，将更新到 v${LATEST_VER}..."
        fi
    fi

    ARCH=$(uname -m)
    case $ARCH in
        x86_64) S_ARCH="amd64" ;;
        aarch64) S_ARCH="arm64" ;;
        *) err "不支持的架构: $ARCH"; return 1 ;;
    esac

    URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${S_ARCH}.tar.gz"
    info "正在下载 Sing-box v$LATEST_VER ($S_ARCH)..."

    if ! wget -O sing-box.tar.gz "$URL"; then
        err "下载 Sing-box 失败，请检查网络！"
        return 1
    fi

    tar -zxvf sing-box.tar.gz

    mkdir -p "$(dirname "$SINGBOX_BIN")"

    if ls sing-box-*/sing-box >/dev/null 2>&1; then
        mv sing-box-*/sing-box "$SINGBOX_BIN"
        chmod +x "$SINGBOX_BIN"
    else
        err "解压后未找到二进制文件！"
        return 1
    fi

    rm -rf sing-box.tar.gz sing-box-*/

    mkdir -p "$SINGBOX_CONF_DIR"
    if [[ ! -f "$SINGBOX_CONF_PATH" ]]; then
        echo '{"log": {"level": "info", "timestamp": true}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]}' > "$SINGBOX_CONF_PATH"
    fi

    create_service_files
    # 更新二进制后：先询问是否对配置文件做平滑升级（适配新版配置规范），再重启生效
    if [[ "$was_installed" -eq 1 ]]; then
        sb_migrate_config_after_update "$current_ver" "$LATEST_VER"
        restart_singbox || warn "重启 Sing-box 失败，请手动重启服务。"
    fi
    info "Sing-box 已安装并配置服务。"
}
