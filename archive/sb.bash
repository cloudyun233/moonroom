#!/usr/bin/env bash
#
# Sing-box 一键配置脚本
# 功能：安装和配置 Sing-box 代理服务，支持 VLESS Reality、Hysteria2 协议（TUIC v5 已禁用）
# 依赖：curl, wget, jq, nftables, openssl, tar, cron
# 支持：Debian/Ubuntu, CentOS, Alpine Linux
#
# 使用方法：直接运行脚本，通过菜单选择操作
#

set -o pipefail

SB_MODULE_BASE_URL="${SB_MODULE_BASE_URL:-https://raw.githubusercontent.com/cloudyun233/moonroom/refs/heads/main/archive/sb}"
SB_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"
SB_MODULE_TMP_DIR=""

sb_cleanup_modules(){
    if [[ -n "$SB_MODULE_TMP_DIR" && -d "$SB_MODULE_TMP_DIR" ]]; then
        rm -rf "$SB_MODULE_TMP_DIR"
    fi
}
trap sb_cleanup_modules EXIT

# 将 raw.githubusercontent.com 链接转为 jsdelivr 镜像（用于 429 限流回退）
sb_github_mirror_url(){
    local url="$1"
    if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/refs/heads/([^/]+)/(.*)$ ]]; then
        echo "https://cdn.jsdelivr.net/gh/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}@${BASH_REMATCH[3]}/${BASH_REMATCH[4]}"
    fi
}

sb_fetch_module(){
    local url="$1"
    local out="$2"
    local mirror
    mirror=$(sb_github_mirror_url "$url")

    # 本地文件路径 (file://) 直接复制，避免 curl/wget 对 file 协议的兼容差异
    if [[ "$url" == file://* ]]; then
        cp "${url#file://}" "$out"
        return
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$out" || { [[ -n "$mirror" ]] && curl -fsSL "$mirror" -o "$out"; }
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$out" "$url" || { [[ -n "$mirror" ]] && wget -qO "$out" "$mirror"; }
    else
        echo "[错误] 未找到 curl 或 wget，无法加载 Sing-box 模块：$url" >&2
        return 1
    fi
}

sb_source_module(){
    local name="$1"
    local local_path="$SB_SCRIPT_DIR/sb/${name}.bash"
    local remote_url="$SB_MODULE_BASE_URL/${name}.bash"
    local loaded_path=""

    if [[ -f "$local_path" ]]; then
        loaded_path="$local_path"
    else
        if [[ -z "$SB_MODULE_TMP_DIR" ]]; then
            SB_MODULE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sb-modules.XXXXXX")"
        fi
        loaded_path="$SB_MODULE_TMP_DIR/${name}.bash"
        sb_fetch_module "$remote_url" "$loaded_path" || return 1
    fi

    # shellcheck source=/dev/null
    source "$loaded_path"
}

sb_load_modules(){
    local modules=(
        common
        service
        firewall
        protocols
        maintenance
        menu
    )
    local module

    for module in "${modules[@]}"; do
        sb_source_module "$module" || exit 1
    done
}

main(){
    check_sys
    while true; do
        show_menu
        echo
        read -rp "按 Enter 键继续..."
    done
}

sb_load_modules

if [[ "${SB_SKIP_MAIN:-0}" != "1" ]]; then
    main "$@"
fi
