#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
entry="$repo_root/archive/sb.bash"
module_dir="$repo_root/archive/sb"
modules=(
  common
  service
  firewall
  protocols
  maintenance
  menu
)

[[ -f "$entry" ]] || {
  echo "missing entry: $entry" >&2
  exit 1
}

for module in "${modules[@]}"; do
  path="$module_dir/$module.bash"
  [[ -f "$path" ]] || {
    echo "missing module: $path" >&2
    exit 1
  }
done

bash -n "$entry"
SB_SKIP_MAIN=1 bash "$entry"
for module in "${modules[@]}"; do
  bash -n "$module_dir/$module.bash"
done

export SB_SKIP_MAIN=1
# shellcheck source=/dev/null
source "$entry"

for fn in check_sys install_singbox config_vless run_ip_sentinel_agent show_menu sb_ver_ge sb_get_core_version sb_migrate_config_after_update sb_apply_config_migration; do
  declare -F "$fn" >/dev/null || {
    echo "missing function: $fn" >&2
    exit 1
  }
done

menu_output="$(printf '0\n' | show_menu 2>&1 || true)"
grep -q 'IP-Sentinel' <<< "$menu_output" || {
  echo "menu does not contain IP-Sentinel option" >&2
  exit 1
}

isolated="$(mktemp -d)"
trap 'rm -rf "$isolated"' EXIT
mkdir -p "$isolated/archive"
cp "$entry" "$isolated/archive/sb.bash"
(
  export SB_SKIP_MAIN=1
  export SB_MODULE_BASE_URL="file://$module_dir"
  # shellcheck source=/dev/null
  source "$isolated/archive/sb.bash"
  declare -F run_ip_sentinel_agent >/dev/null
)

# ---- config migration unit tests (require jq) ----
if command -v jq >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  source "$entry"

  # Windows 下原生 jq.exe 不识别 POSIX 路径，用包装脚本做 cygpath 转换（Linux 上直通）
  if command -v cygpath >/dev/null 2>&1; then
    real_jq="$(command -v jq)"
    cat > "$isolated/jq" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  if [[ "\$a" == /* ]] && command -v cygpath >/dev/null 2>&1; then
    args+=("\$(cygpath -m "\$a")")
  else
    args+=("\$a")
  fi
done
exec "$real_jq" "\${args[@]}"
EOF
    chmod +x "$isolated/jq"
    export PATH="$isolated:$PATH"
  fi

  # sb_ver_ge: 语义化版本比较
  sb_ver_ge 1.14.0 1.14.0 || { echo "sb_ver_ge: 1.14.0>=1.14.0 should be true" >&2; exit 1; }
  sb_ver_ge 1.15.0 1.14.0 || { echo "sb_ver_ge: 1.15.0>=1.14.0 should be true" >&2; exit 1; }
  sb_ver_ge 1.13.2 1.2.9  || { echo "sb_ver_ge: 1.13.2>=1.2.9 should be true" >&2; exit 1; }
  if sb_ver_ge 1.13.2 1.14.0; then echo "sb_ver_ge: 1.13.2>=1.14.0 should be false" >&2; exit 1; fi
  if sb_ver_ge "" 1.14.0; then echo "sb_ver_ge: empty version should not pass" >&2; exit 1; fi

  # sb_apply_config_migration: tls.acme -> tls.certificate_provider
  mig_file="$isolated/mig.json"
  printf '%s' '{"log":{},"inbounds":[{"type":"hysteria2","tag":"hysteria2-in","tls":{"enabled":true,"alpn":["h3"],"server_name":"a.com","acme":{"domain":["a.com"],"email":"a@b.c","data_directory":"/etc/sing-box"}}}],"outbounds":[{"type":"direct","tag":"direct"}]}' > "$mig_file"
  sb_apply_config_migration "$mig_file" > "$mig_file.out"
  jq -e '
    .inbounds[0].tls.certificate_provider.type == "acme" and
    .inbounds[0].tls.certificate_provider.domain == ["a.com"] and
    .inbounds[0].tls.certificate_provider.email == "a@b.c" and
    .inbounds[0].tls.certificate_provider.data_directory == "/etc/sing-box" and
    .inbounds[0].tls.server_name == "a.com" and
    .inbounds[0].tls.enabled == true and
    (.inbounds[0].tls | has("acme") | not) and
    (.outbounds == [{"type":"direct","tag":"direct"}])
  ' "$mig_file.out" >/dev/null || { echo "acme -> certificate_provider migration failed" >&2; exit 1; }

  # sb_apply_config_migration: 无 acme 的配置保持原样
  noacme_file="$isolated/noacme.json"
  printf '%s' '{"inbounds":[{"type":"vless","tls":{"enabled":true,"reality":{"enabled":true}}}]}' > "$noacme_file"
  sb_apply_config_migration "$noacme_file" > "$noacme_file.out"
  jq -e '
    .inbounds[0].tls.certificate_provider == null and
    .inbounds[0].tls.reality.enabled == true
  ' "$noacme_file.out" >/dev/null || { echo "no-acme config should stay untouched" >&2; exit 1; }

  echo "config migration tests passed"
else
  echo "jq not found, skip config migration tests"
fi

echo "sb module smoke test passed"
