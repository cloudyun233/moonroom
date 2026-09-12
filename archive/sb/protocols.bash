# 清理已存在的证书文件
cleanup_cert_files(){
    local cert_path="$SINGBOX_CONF_DIR/singbox.crt"
    local key_path="$SINGBOX_CONF_DIR/singbox.key"

    if [[ -f "$cert_path" ]] || [[ -f "$key_path" ]]; then
        info "检测到已存在的证书文件，正在清理..."
        rm -f "$cert_path" "$key_path"
        info "旧证书文件已清理。"
    fi
}

# 生成 TLS 配置（支持自签名证书和 ACME）
generate_tls_config(){
    local cn_domain="${1:-$DEFAULT_DOMAIN}"  # 自签证书 CN（ACME 模式忽略，使用用户输入域名）
    echo "证书模式:" >&2
    echo "1. 自签名(需要允许不安全)" >&2
    echo "2. ACME (需要域名)" >&2
    read -erp "选择 [1]: " TLS_CERT_MODE

    if [[ "$TLS_CERT_MODE" == "2" ]]; then
        read -erp "域名: " domain
        read -erp "邮箱: " email
        # sing-box 1.14.0 起 TLS 内联 acme 已废弃（1.16.0 移除），新核心使用 certificate_provider 格式
        local core_ver
        core_ver=$(sb_get_core_version)
        if [[ -z "$core_ver" ]] || sb_ver_ge "$core_ver" "1.14.0"; then
            jq -n --arg domain "$domain" --arg email "$email" --arg data_dir "$SINGBOX_CONF_DIR" '
                {
                    enabled: true,
                    alpn: ["h3"],
                    server_name: $domain,
                    certificate_provider: {
                        type: "acme",
                        domain: [$domain],
                        email: $email,
                        data_directory: $data_dir
                    }
                }
            '
        else
            jq -n --arg domain "$domain" --arg email "$email" --arg data_dir "$SINGBOX_CONF_DIR" '
                {
                    enabled: true,
                    alpn: ["h3"],
                    server_name: $domain,
                    acme: {
                        domain: [$domain],
                        email: $email,
                        data_directory: $data_dir
                    }
                }
            '
        fi
    else
        local cert_path="$SINGBOX_CONF_DIR/singbox.crt"
        local key_path="$SINGBOX_CONF_DIR/singbox.key"

        cleanup_cert_files

        openssl req -x509 -newkey rsa:2048 -nodes -sha256 -keyout "$key_path" -out "$cert_path" -days 3650 -subj "/CN=$cn_domain" || true
        jq -n --arg cert "$cert_path" --arg key "$key_path" '
            {
                enabled: true,
                alpn: ["h3"],
                certificate_path: $cert,
                key_path: $key
            }
        '
    fi
}

# 添加入站配置到 JSON 配置文件（使用 jq 处理）
add_inbound(){
    local new_inbound="$1"

    # 确保配置目录存在
    mkdir -p "$SINGBOX_CONF_DIR"

    # 确保配置文件存在
    if [[ ! -f "$SINGBOX_CONF_PATH" ]]; then
        echo '{"log": {"level": "info", "timestamp": true}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}]}' > "$SINGBOX_CONF_PATH"
    fi

    # 移除旧的同类型 inbound（如果有）
    local type=$(echo "$new_inbound" | jq -r '.type' || true)
    jq --arg type "$type" 'del(.inbounds[]? | select(.type == $type))' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp" && mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH" || true

    # 添加入站
    if jq --argjson new "$new_inbound" '.inbounds += [$new]' "$SINGBOX_CONF_PATH" > "${SINGBOX_CONF_PATH}.tmp"; then
        mv "${SINGBOX_CONF_PATH}.tmp" "$SINGBOX_CONF_PATH"
    else
        err "添加配置失败 (jq error)"
        return 1
    fi
    restart_singbox
}

# 配置 VLESS Reality 协议
config_vless(){
    info "正在配置 VLESS Reality..."
    local default_port=$(get_preferred_port "vless")
    read -rp "请输入监听端口 [默认: $default_port]: " port
    port=${port:-$default_port}
    info "使用端口: $port"

    open_port "$port" "tcp"

    local dest_domain
    dest_domain=$(get_random_domain)
    local uuid=$(get_random_uuid)
    local short_id=$(openssl rand -hex 4)
    local keys=$("$SINGBOX_BIN" generate reality-keypair)
    local private_key=$(echo "$keys" | grep "PrivateKey" | cut -d: -f2 | tr -d ' \\"')
    local public_key=$(echo "$keys" | grep "PublicKey" | cut -d: -f2 | tr -d ' \\"')

    local inbound=$(jq -n --arg port "$port" --arg uuid "$uuid" --arg dest "$dest_domain" --arg pk "$private_key" --arg sid "$short_id" '
        {
            type: "vless",
            tag: "vless-reality",
            listen: "::",
            listen_port: ($port|tonumber),
            users: [
                {
                    uuid: $uuid,
                    flow: "xtls-rprx-vision"
                }
            ],
            tls: {
                enabled: true,
                server_name: $dest,
                reality: {
                    enabled: true,
                    handshake: {
                        server: $dest,
                        server_port: 443
                    },
                    private_key: $pk,
                    short_id: [$sid]
                }
            }
        }
    ')

    add_inbound "$inbound"
    info "VLESS Reality 已配置完成。"
    echo "UUID: $uuid"
    echo "公钥: $public_key"
    echo "短 ID: $short_id"
    echo "端口: $port"
    echo "域名: $dest_domain"
}

# 配置 Hysteria2 协议
config_hy2(){
    info "正在配置 Hysteria2..."
    local default_port=$(get_preferred_port "hysteria2")
    read -rp "请输入监听端口 [默认: $default_port]: " port
    port=${port:-$default_port}
    info "使用端口: $port"

    open_port "$port" "udp"

    local password=$(get_random_password)
    local dest_domain
    dest_domain=$(get_random_domain)

    local tls_config=$(generate_tls_config "$dest_domain")

    # 询问是否启用 obfs
    local obfs_config='{}'
    read -rp "是否启用 obfs 混淆？[y/N]: " enable_obfs
    if [[ "$enable_obfs" =~ ^[Yy]$ ]]; then
        local obfs_password=$(get_random_password)
        obfs_config=$(jq -n --arg pass "$obfs_password" '
            {
                type: "salamander",
                password: $pass
            }
        ')
    fi

    local inbound=$(jq -n --arg port "$port" --arg pass "$password" --argjson tls "$tls_config" --argjson obfs "$obfs_config" --arg domain "$dest_domain" '
        {
            type: "hysteria2",
            tag: "hysteria2-in",
            listen: "::",
            listen_port: ($port|tonumber),
            users: [
                {
                    password: $pass
                }
            ],
            tls: $tls,
            masquerade: {
                type: "proxy",
                url: "https://\($domain)",
                rewrite_host: true
            }
        } + (if $obfs != {} then {obfs: $obfs} else {} end)
    ')

    add_inbound "$inbound"
    info "Hysteria2 已配置完成。"
    echo "密码: $password"
    echo "端口: $port"
    echo "伪装域名: $dest_domain"
    if [[ "$obfs_config" != "{}" ]]; then
        echo "Obfs 密码: $(echo "$obfs_config" | jq -r '.password')"
    fi
}

# 配置 TUIC v5 协议
# [已禁用] TUIC 配置功能已注释掉，如需恢复请取消以下注释
# config_tuic(){
#     info "正在配置 TUIC v5..."
#     local default_port=$(get_preferred_port "tuic")
#     read -rp "请输入监听端口 [默认: $default_port]: " port
#     port=${port:-$default_port}
#     info "使用端口: $port"
#
#     open_port "$port" "udp"
#
#     local uuid=$(get_random_uuid)
#     local password=$(get_random_password)
#
#     local tls_config=$(generate_tls_config)
#
#     local inbound=$(jq -n --arg port "$port" --arg uuid "$uuid" --arg pass "$password" --argjson tls "$tls_config" '
#         {
#             type: "tuic",
#             tag: "tuic-in",
#             listen: "::",
#             listen_port: ($port|tonumber),
#             users: [
#                 {
#                     name: "cloudyun",
#                     uuid: $uuid,
#                     password: $pass
#                 }
#             ],
#             congestion_control: "bbr",
#             auth_timeout: "3s",
#             zero_rtt_handshake: true,
#             tls: $tls
#         }
#     ')
#
#     add_inbound "$inbound"
#     info "TUIC v5 已配置完成。"
#     echo "UUID: $uuid"
#     echo "密码: $password"
#     echo "端口: $port"
# }
