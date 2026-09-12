# 清除所有入站配置
clear_config(){
    info "正在清除入栈配置..."

    # 清除证书文件
    local cert_files=(
        "$SINGBOX_CONF_DIR/singbox.crt"
        "$SINGBOX_CONF_DIR/singbox.key"
    )

    local cert_found=false
    for cert_file in "${cert_files[@]}"; do
        if [[ -f "$cert_file" ]]; then
            rm -f "$cert_file"
            cert_found=true
        fi
    done

    if [[ "$cert_found" == true ]]; then
        info "证书文件已清理。"
    fi

    # 只清除入栈配置，保留出站配置
    jq '.inbounds = []' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp" && mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH"

    # 清理防火墙
    if command -v nft >/dev/null; then
        nft flush table inet singbox_nat || true
        nft delete table inet singbox_nat || true
        nft delete table inet singbox_filter || true
    elif command -v firewall-cmd >/dev/null; then
        warn "Firewalld 用户请注意：脚本无法自动精确删除所有开放端口，请手动检查 'firewall-cmd --list-all'。"
        firewall-cmd --reload
    fi

    restart_singbox
    info "入栈配置已清除。"
}

# 运行服务器测试脚本
run_test_script(){ bash <(curl -Ls Check.Place); }

# 安装 BBRv3 内核优化
run_bbr(){ bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/refs/heads/main/install.sh || curl -fsSL https://cdn.jsdelivr.net/gh/byJoey/Actions-bbr-v3@main/install.sh); }

# 运行 IP-Sentinel Agent 客户端脚本
run_ip_sentinel_agent(){
    info "正在执行 IP-Sentinel Agent 客户端脚本..."
    local script
    script=$(curl -fsSL https://raw.githubusercontent.com/hotyue/IP-Sentinel/main/install.sh || curl -fsSL https://cdn.jsdelivr.net/gh/hotyue/IP-Sentinel@main/install.sh)
    if [[ -z "$script" ]]; then
        err "拉取 IP-Sentinel 脚本失败（可能被限流），请稍后重试。"
        return 1
    fi
    bash -c "$script"
}

# 卸载 Sing-box 及相关配置
uninstall_singbox(){
    rm -rf "$SINGBOX_BIN" "$SINGBOX_CONF_DIR"

    # 清理防火墙
    if command -v nft >/dev/null; then
        nft flush table inet singbox_nat || true
        nft delete table inet singbox_nat || true
        nft delete table inet singbox_filter || true
    fi

    if [[ "$RELEASE" == "alpine" ]]; then
        rc-service sing-box stop || true
        rc-update del sing-box || true
        rm /etc/init.d/sing-box || true
    else
        systemctl disable --now sing-box || true
        rm /etc/systemd/system/sing-box.service || true
        systemctl daemon-reload || true
    fi
    info "已卸载。"
}

# 配置定时重启任务（每月 1 日 20:00 UTC）
configure_cron_reboot(){
    info "正在检查并配置系统时间为 UTC..."

    current_timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || date +%Z)

    if [[ "$current_timezone" != "UTC" ]]; then
        info "当前时区不是 UTC，正在设置为 UTC..."
        if command -v timedatectl &>/dev/null; then
            timedatectl set-timezone UTC
            info "时区已设置为 UTC"
        else
            if [[ -f /etc/localtime ]]; then
                rm -f /etc/localtime
            fi
            ln -sf /usr/share/zoneinfo/UTC /etc/localtime
            info "时区已设置为 UTC (通过符号链接)"
        fi
    else
        info "当前时区已经是 UTC"
    fi

    # 显示当前时间
    info "当前系统时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    info "正在配置每月 1 日 20:00 UTC 重启。"
    # 检查是否存在
    crontab -l 2>/dev/null | grep -v "/sbin/reboot" > mycron || true
    echo "0 20 1 * * /sbin/reboot" >> mycron
    crontab mycron
    rm mycron
    info "定时任务已添加。"
}

# ---------------------------------------------------------------------------
# 核心升级后的配置文件平滑迁移（依据官方迁移指南）
# https://sing-box.sagernet.org/migration/
#  - 1.13.0 移除 1.11 废弃项: 特殊出站 block/dns、入站 sniff/sniff_timeout/
#    domain_strategy、direct 出站 override_address/override_port
#  - 1.14.0 移除 1.12 废弃项: 旧 DNS 服务器 address 格式
#  - TLS 内联 acme 选项于 1.14.0 废弃，官方将在 1.16.0 移除，
#    新写法为 certificate_provider (内联对象或顶层 certificate_providers 引用)
# 本脚本迁移范围: 脚本自身生成的 VLESS Reality / Hysteria2 入站配置，
# 重点是 Hysteria2 ACME 证书配置的 tls.acme -> tls.certificate_provider 升级
# ---------------------------------------------------------------------------

# 支持配置平滑升级的版本范围（用于向用户展示）
SB_MIGRATION_SOURCE_RANGE="v1.9.0 ~ v1.13.x 旧格式配置"
SB_MIGRATION_TARGET_VER="v1.14.0+ 新格式"

# 应用配置迁移规则（旧格式 -> 当前核心格式）
# 用法: sb_apply_config_migration <配置文件路径>  (迁移结果输出到 stdout)
sb_apply_config_migration(){
    local conf_file="$1"
    jq '
        .inbounds = ((.inbounds // []) | map(
            if (.tls | type) == "object" and (.tls | has("acme")) then
                .tls.certificate_provider = (.tls.acme + {"type": "acme"})
                | .tls |= del(.acme)
            else . end
        ))
    ' "$conf_file"
}

# 执行配置迁移: 备份 -> 迁移 -> 校验，校验失败自动回滚
sb_do_config_migration(){
    local backup_path="$SINGBOX_CONF_PATH.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -a "$SINGBOX_CONF_PATH" "$backup_path"; then
        err "创建配置备份失败，已取消迁移。"
        return 1
    fi
    info "已备份原配置到 $backup_path"

    local tmp_file="$SINGBOX_CONF_PATH.migrate.tmp"
    if ! sb_apply_config_migration "$SINGBOX_CONF_PATH" > "$tmp_file"; then
        err "配置迁移处理失败 (jq error)，原配置未修改。"
        rm -f "$tmp_file"
        return 1
    fi
    mv "$tmp_file" "$SINGBOX_CONF_PATH"

    if "$SINGBOX_BIN" check -c "$SINGBOX_CONF_PATH" >/dev/null 2>&1; then
        info "配置文件平滑升级完成，已通过 v$(sb_get_core_version) 核心校验。"
        return 0
    fi

    warn "迁移后的配置校验未通过，正在回滚..."
    cp -a "$backup_path" "$SINGBOX_CONF_PATH"
    err "已回滚到迁移前配置，请检查 $SINGBOX_CONF_PATH 或手动调整。"
    return 1
}

# 核心升级后调用: 询问用户是否需要完成配置文件平滑升级
# 用法: sb_migrate_config_after_update <旧核心版本> <新核心版本>
sb_migrate_config_after_update(){
    local old_ver="${1:-}" new_ver="${2:-}"
    if [[ ! -f "$SINGBOX_CONF_PATH" ]]; then
        return 0
    fi

    echo
    info "核心已从 v${old_ver:-未知} 更新到 v${new_ver:-未知}。"
    info "根据官方文档，配置文件规范有如下变化："
    echo "  - 1.13.0 起移除特殊出站 (block/dns)、入站 sniff/domain_strategy 等旧字段"
    echo "  - 1.14.0 起移除旧 DNS 服务器 address 格式"
    echo "  - TLS 内联 acme 已于 1.14.0 废弃（官方将在 1.16.0 移除），新写法为 certificate_provider"
    info "当前支持配置升级的版本：${SB_MIGRATION_SOURCE_RANGE} -> ${SB_MIGRATION_TARGET_VER}"
    info "（迁移范围：本脚本生成的 VLESS Reality / Hysteria2 入站配置，含 Hysteria2 ACME 证书配置）"

    # 先用新核心对现有配置做兼容性预检，帮助用户决策
    if "$SINGBOX_BIN" check -c "$SINGBOX_CONF_PATH" >/dev/null 2>&1; then
        info "预检：当前配置已通过 v${new_ver} 核心校验，可继续使用。"
    else
        warn "预检：当前配置未通过 v${new_ver} 核心校验，建议执行平滑升级。"
    fi

    local sb_mig_answer=""
    read -rp "是否需要完成配置文件平滑升级？[y/N]: " sb_mig_answer
    if [[ ! "$sb_mig_answer" =~ ^[Yy]$ ]]; then
        info "已跳过配置迁移，现有配置将保持不变。"
        return 0
    fi

    sb_do_config_migration
}
