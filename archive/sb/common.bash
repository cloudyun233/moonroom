# 全局变量
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF_DIR="/usr/local/etc/sing-box"
SINGBOX_CONF_PATH="$SINGBOX_CONF_DIR/config.json"
NFT_CONF="/etc/nftables.conf"
DEFAULT_DOMAIN="www.cho-kaguyahime.com"

# 颜色输出函数
info(){ echo -e "\e[1;34m[信息]\e[0m $*"; }
warn(){ echo -e "\e[1;33m[警告]\e[0m $*"; }
err(){ echo -e "\e[1;31m[错误]\e[0m $*"; }

# 检测操作系统类型，设置包管理器变量
check_sys(){
    if [[ -f /etc/redhat-release ]]; then
        RELEASE="centos"
        PM="yum"
    elif cat /etc/issue | grep -q -E -i "debian|ubuntu"; then
        RELEASE="debian"
        PM="apt"
    elif cat /etc/issue | grep -q -E -i "alpine"; then
        RELEASE="alpine"
        PM="apk"
    else
        err "不支持的操作系统"
        exit 1
    fi
}

install_dependencies(){
    info "正在安装依赖..."
    info "根据系统类型使用 $PM 安装必要依赖包"
    if [[ "$PM" == "apt" ]]; then
        apt update && apt install -y curl wget jq nftables openssl tar cron || { err "依赖安装失败"; return 1; }
    elif [[ "$PM" == "apk" ]]; then
        apk add curl wget jq nftables openssl tar cronie || { err "依赖安装失败"; return 1; }
        rc-update add crond
        rc-service crond start
    elif [[ "$PM" == "yum" ]]; then
        yum install -y curl wget jq nftables openssl tar cronie || { err "依赖安装失败"; return 1; }
        systemctl enable crond
        systemctl start crond
    fi
}

# 生成随机 UUID
get_random_uuid(){ uuidgen || cat /proc/sys/kernel/random/uuid; }

# 生成随机密码
get_random_password(){ openssl rand -base64 18; }

# 读取当前已安装核心的版本号（如 1.14.0），未安装或失败时输出空串
sb_get_core_version(){
    "$SINGBOX_BIN" version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# 语义化版本比较: sb_ver_ge <a> <b>，当 a >= b 时返回 0
# 纯 bash 实现，避免依赖 sort -V（busybox sort 不支持该选项）
sb_ver_ge(){
    local a="${1:-}" b="${2:-}"
    [[ "$a" =~ ^[0-9]+(\.[0-9]+)*$ && "$b" =~ ^[0-9]+(\.[0-9]+)*$ ]] || return 2
    local -a pa pb
    IFS=. read -r -a pa <<< "$a"
    IFS=. read -r -a pb <<< "$b"
    local i x y
    for i in 0 1 2; do
        x=${pa[i]:-0}
        y=${pb[i]:-0}
        if (( x != y )); then
            (( x > y ))
            return
        fi
    done
    return 0
}

# 从 domains.txt 随机选取一个伪装域名
# 本地 sb/domains.txt 优先；不存在则尝试从远程拉取到模块临时目录
# 拉取失败或文件为空时回退到 DEFAULT_DOMAIN（用户无感知）
get_random_domain(){
    local local_path="${SB_SCRIPT_DIR:-.}/sb/domains.txt"
    local remote_url="${SB_MODULE_BASE_URL:-https://raw.githubusercontent.com/cloudyun233/jump-endfield/refs/heads/main/archive/sb}/domains.txt"
    local domains_file=""

    if [[ -f "$local_path" ]]; then
        domains_file="$local_path"
    else
        if [[ -z "${SB_MODULE_TMP_DIR:-}" ]]; then
            SB_MODULE_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sb-modules.XXXXXX")"
        fi
        domains_file="$SB_MODULE_TMP_DIR/domains.txt"
        if ! sb_fetch_module "$remote_url" "$domains_file" 2>/dev/null; then
            echo "$DEFAULT_DOMAIN"
            return
        fi
    fi

    # 随机选取一个非空、非注释行（bash $RANDOM 分布优于 awk rand()）
    local domains=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && domains+=("$line")
    done < <(grep -vE '^[[:space:]]*(#|$)' "$domains_file" 2>/dev/null)

    if [[ ${#domains[@]} -eq 0 ]]; then
        echo "$DEFAULT_DOMAIN"
    else
        echo "${domains[$((RANDOM % ${#domains[@]}))]}"
    fi
}
