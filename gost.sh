#!/usr/bin/env bash

Green_font_prefix="\033[32m"
Red_font_prefix="\033[31m"
Green_background_prefix="\033[42;37m"
Font_color_suffix="\033[0m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"

shell_version="3.0.0"
default_gost_ver="3.2.6"
ct_new_ver="${default_gost_ver}"
gost_bin="${GOST_BIN:-/usr/bin/gost}"
gost_conf_path="/etc/gost/config.yaml"
raw_conf_path="/etc/gost/rawconf"
list_dir="/etc/gost/lists"
service_path="/usr/lib/systemd/system/gost.service"
repo_slug_default="torr9522/Gost-v3"
repo_branch_default="main"
self_update_url="https://raw.githubusercontent.com/${repo_slug_default}/${repo_branch_default}/gost.sh"
latest_release_api="https://api.github.com/repos/go-gost/gost/releases/latest"

release=""
bit=""
service_seq=0
target_seq=0
chain_seq=0
hop_seq=0
node_seq=0
services_tmp=""
chains_tmp=""
has_strategy_fallback=0

rule_type=""
rule_listen_value=""
rule_target_host=""
rule_target_value=""
rule_tls_verify="n"
rule_auth_mode="auth"
rule_cert_mode=""
rule_cert_domain=""
rule_cert_method=""
rule_cert_path=""
rule_key_path=""
rule_cert_kind=""

rule_record=""
parsed_rule_type=""
parsed_listen_value=""
parsed_target_host=""
parsed_target_value=""
parsed_auth_mode="auth"
parsed_cert_mode=""
parsed_cert_domain=""
parsed_cert_path=""
parsed_key_path=""
parsed_cert_kind=""
parsed_listen_secret=""
rule_flow_result="add"

log_info() {
  echo -e "${Info} $*"
}

log_error() {
  echo -e "${Error} $*" >&2
}

exit_error() {
  log_error "$*"
  exit 1
}

reset_rule_context() {
  rule_type=""
  rule_listen_value=""
  rule_target_host=""
  rule_target_value=""
  rule_tls_verify="n"
  rule_auth_mode="auth"
  rule_cert_mode=""
  rule_cert_domain=""
  rule_cert_method=""
  rule_cert_path=""
  rule_key_path=""
  rule_cert_kind=""
  rule_flow_result="add"
}

proxy_type_label() {
  case "$1" in
  socks)
    printf 'socks5'
    ;;
  http)
    printf 'http'
    ;;
  ss)
    printf 'shadowsocks'
    ;;
  *)
    printf '%s' "$1"
    ;;
  esac
}

rule_type_label() {
  case "$1" in
  https)
    printf 'https'
    ;;
  *)
    proxy_type_label "$1"
    ;;
  esac
}

has_ufw() {
  command -v ufw >/dev/null 2>&1
}

ensure_ufw_rule() {
  local port="$1"
  [[ -z "${port}" ]] && return 0
  has_ufw || return 0
  ufw status | grep -qE "^[[:space:]]*${port}/tcp[[:space:]]+ALLOW IN" && return 0
  ufw allow "${port}/tcp" >/dev/null 2>&1 || true
}

delete_ufw_rule() {
  local port="$1"
  [[ -z "${port}" ]] && return 0
  [[ "${port}" == "22" ]] && return 0
  has_ufw || return 0
  ufw status | grep -qE "^[[:space:]]*${port}/tcp[[:space:]]+ALLOW IN" || return 0
  ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true
}

collect_required_tcp_ports() {
  ensure_rawconf_file
  awk '
    {
      split($0, parts, "#")
      split(parts[1], tl, "/")
      type=tl[1]
      listen=tl[2]
      if (type == "nonencrypt" || type == "encrypttls" || type == "encryptws" || type == "encryptwss" || type == "peerno" || type == "peertls" || type == "peerws" || type == "peerwss" || type == "cdnno" || type == "cdnws" || type == "cdnwss" || type == "decrypttls" || type == "decryptws" || type == "decryptwss" || type == "ss" || type == "socks" || type == "http" || type == "https") {
        if (listen != "") print listen
      }
    }
  ' "${raw_conf_path}" | sort -u
}

sync_ufw_ports() {
  local -a desired_ports=()
  local -a current_ports=()
  local port

  has_ufw || return 0

  while IFS= read -r port; do
    [[ -n "${port}" ]] && desired_ports+=("${port}")
  done < <(collect_required_tcp_ports)

  if grep -q '^https/' "${raw_conf_path}" 2>/dev/null; then
    desired_ports+=("80")
  fi

  mapfile -t desired_ports < <(printf '%s\n' "${desired_ports[@]}" | awk 'NF' | sort -u)
  mapfile -t current_ports < <(ufw status | awk '/ALLOW IN/ && $1 ~ /^[0-9]+\/tcp$/ { split($1, a, "/"); print a[1] }' | sort -u)

  for port in "${desired_ports[@]}"; do
    [[ "${port}" == "22" ]] && continue
    ensure_ufw_rule "${port}"
  done

  for port in "${current_ports[@]}"; do
    [[ -z "${port}" ]] && continue
    [[ "${port}" == "22" ]] && continue
    if ! printf '%s\n' "${desired_ports[@]}" | grep -qx "${port}"; then
      delete_ufw_rule "${port}"
    fi
  done
}

ensure_http_challenge_port() {
  ensure_ufw_rule "80"
}

cert_base_dir() {
  printf '%s\n' "${HOME}/gost_cert"
}

cert_dir_for_kind() {
  local kind="$1"
  local name="$2"
  case "${kind}" in
  domain)
    printf '%s/domain/%s\n' "$(cert_base_dir)" "${name}"
    ;;
  ip)
    printf '%s/ip/%s\n' "$(cert_base_dir)" "${name}"
    ;;
  *)
    printf '%s\n' "$(cert_base_dir)"
    ;;
  esac
}

yaml_quote() {
  local value
  value=$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")
  printf "'%s'" "$value"
}

check_root() {
  [[ $EUID != 0 ]] && exit_error "当前非 ROOT 账号，无法继续操作。"
}

check_sys() {
  if [[ -f /etc/redhat-release ]]; then
    release="centos"
  elif grep -qiE "debian" /etc/issue 2>/dev/null || grep -qiE "debian" /proc/version 2>/dev/null; then
    release="debian"
  elif grep -qiE "ubuntu" /etc/issue 2>/dev/null || grep -qiE "ubuntu" /proc/version 2>/dev/null; then
    release="ubuntu"
  elif grep -qiE "centos|red hat|redhat" /etc/issue 2>/dev/null || grep -qiE "centos|red hat|redhat" /proc/version 2>/dev/null; then
    release="centos"
  else
    exit_error "暂不支持当前系统，请在 Debian / Ubuntu / CentOS 上使用。"
  fi

  case "$(uname -m)" in
  x86_64)
    bit="amd64"
    ;;
  i386 | i686)
    bit="386"
    ;;
  aarch64 | arm64)
    bit="arm64"
    ;;
  armv7l | armv7*)
    bit="armv7"
    ;;
  armv6l | armv6*)
    bit="armv6"
    ;;
  armv5l | armv5*)
    bit="armv5"
    ;;
  riscv64)
    bit="riscv64"
    ;;
  loongarch64)
    bit="loong64"
    ;;
  s390x)
    bit="s390x"
    ;;
  *)
    exit_error "暂不支持的芯片架构: $(uname -m)"
    ;;
  esac
}

Installation_dependency() {
  local missing=0
  command -v curl >/dev/null 2>&1 || missing=1
  command -v tar >/dev/null 2>&1 || missing=1
  command -v gzip >/dev/null 2>&1 || missing=1
  command -v sed >/dev/null 2>&1 || missing=1
  command -v awk >/dev/null 2>&1 || missing=1

  if [[ ${missing} -eq 0 ]]; then
    return 0
  fi

  check_sys
  if [[ ${release} == "centos" ]]; then
    yum update -y
    yum install -y curl tar gzip sed gawk
  else
    apt-get update
    apt-get install -y curl tar gzip sed gawk
  fi
}

check_file() {
  mkdir -p /etc/gost
  mkdir -p "${list_dir}"
  mkdir -p "$(dirname "${service_path}")"
}

write_service_file() {
  cat >"${service_path}" <<EOF
[Unit]
Description=gost
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=always
RestartSec=5
ExecStart=${gost_bin} -C ${gost_conf_path}

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${service_path}"
}

write_placeholder_config() {
  cat >"${gost_conf_path}" <<'EOF'
services:
  - name: placeholder
    addr: 127.0.0.1:65532
    handler:
      type: udp
    listener:
      type: udp
EOF
}

ensure_rawconf_file() {
  check_file
  touch "${raw_conf_path}"
}

current_gost_version() {
  if [[ ! -x "${gost_bin}" ]]; then
    return 1
  fi
  "${gost_bin}" -V 2>/dev/null | awk '{print $2}' | sed 's/^v//'
}

check_new_ver() {
  local latest
  latest=$(curl -fsSL "${latest_release_api}" 2>/dev/null | grep -m1 '"tag_name"' | sed 's/.*"v\{0,1\}\([^"]*\)".*/\1/')
  if [[ -n "${latest}" ]]; then
    ct_new_ver="${latest}"
    log_info "gost 当前最新版本: v${ct_new_ver}"
  else
    ct_new_ver="${default_gost_ver}"
    log_error "获取 gost 最新版本失败，回退到已验证版本 v${ct_new_ver}"
  fi
}

download_gost() {
  local version="$1"
  local tmp_dir archive url
  tmp_dir=$(mktemp -d)
  archive="gost_${version}_linux_${bit}.tar.gz"
  url="https://github.com/go-gost/gost/releases/download/v${version}/${archive}"

  log_info "开始下载 gost v${version}"
  if ! curl -fsSL "${url}" -o "${tmp_dir}/${archive}"; then
    rm -rf "${tmp_dir}"
    exit_error "下载 gost 失败: ${url}"
  fi

  if ! tar -xzf "${tmp_dir}/${archive}" -C "${tmp_dir}" gost; then
    rm -rf "${tmp_dir}"
    exit_error "解压 gost 失败"
  fi

  install -m 0755 "${tmp_dir}/gost" "${gost_bin}"
  rm -rf "${tmp_dir}"
}

normalize_ss_cipher() {
  case "$1" in
  AEAD_CHACHA20_POLY1305)
    printf 'chacha20-ietf-poly1305'
    ;;
  *)
    printf '%s' "$1"
    ;;
  esac
}

normalize_strategy() {
  case "$1" in
  round)
    printf 'round'
    ;;
  random)
    printf 'rand'
    ;;
  fifo)
    has_strategy_fallback=1
    printf 'round'
    ;;
  "")
    printf 'round'
    ;;
  *)
    printf '%s' "$1"
    ;;
  esac
}

resolve_list_file() {
  local name="$1"
  local candidates=(
    "${list_dir}/${name}.txt"
    "/root/${name}.txt"
    "$(pwd)/${name}.txt"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -f "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

extract_yaml_services() {
  awk '
    /^services:/ { in_services=1; next }
    /^chains:/ { in_services=0 }
    in_services { print }
  ' "$1"
}

extract_yaml_chains() {
  awk '
    /^chains:/ { in_chains=1; next }
    in_chains { print }
  ' "$1"
}

rename_fragment() {
  local fragment="$1"
  local service_name="service-${service_seq}"
  local target_name="target-${target_seq}"

  sed -i "s/name: service-0/name: ${service_name}/g" "${fragment}"
  sed -i "s/name: target-0/name: ${target_name}/g" "${fragment}"
  service_seq=$((service_seq + 1))
  target_seq=$((target_seq + 1))

  if grep -q '^chains:' "${fragment}"; then
    local chain_name="chain-${chain_seq}"
    local hop_name="hop-${hop_seq}"
    local node_name="node-${node_seq}"

    sed -i "s/chain-0/${chain_name}/g" "${fragment}"
    sed -i "s/name: hop-0/name: ${hop_name}/g" "${fragment}"
    sed -i "s/name: node-0/name: ${node_name}/g" "${fragment}"
    chain_seq=$((chain_seq + 1))
    hop_seq=$((hop_seq + 1))
    node_seq=$((node_seq + 1))
  fi
}

append_cli_fragment() {
  local fragment
  fragment=$(mktemp)

  if ! "${gost_bin}" "$@" -O yaml >"${fragment}"; then
    rm -f "${fragment}"
    exit_error "渲染 v3 配置失败: ${*}"
  fi

  rename_fragment "${fragment}"
  extract_yaml_services "${fragment}" >>"${services_tmp}"
  if grep -q '^chains:' "${fragment}"; then
    extract_yaml_chains "${fragment}" >>"${chains_tmp}"
  fi
  rm -f "${fragment}"
}

append_direct_balance_service() {
  local proto="$1"
  local listen_port="$2"
  local list_name="$3"
  local strategy_raw="$4"
  local strategy file
  local -a nodes

  file=$(resolve_list_file "${list_name}") || exit_error "负载均衡列表文件不存在: ${list_name}.txt"
  mapfile -t nodes < <(grep -vE '^[[:space:]]*(#|$)' "${file}")
  [[ ${#nodes[@]} -eq 0 ]] && exit_error "负载均衡列表为空: ${file}"

  strategy=$(normalize_strategy "${strategy_raw}")
  local service_name="service-${service_seq}"
  service_seq=$((service_seq + 1))

  {
    printf "  - name: %s\n" "${service_name}"
    printf "    addr: %s\n" "$(yaml_quote ":${listen_port}")"
    printf "    handler:\n"
    printf "      type: %s\n" "${proto}"
    printf "    listener:\n"
    printf "      type: %s\n" "${proto}"
    printf "    forwarder:\n"
    printf "      nodes:\n"
    local node
    for node in "${nodes[@]}"; do
      printf "        - name: target-%s\n" "${target_seq}"
      printf "          addr: %s\n" "$(yaml_quote "${node}")"
      target_seq=$((target_seq + 1))
    done
    printf "      selector:\n"
    printf "        strategy: %s\n" "${strategy}"
  } >>"${services_tmp}"
}

append_chain_balance_service() {
  local proto="$1"
  local listen_port="$2"
  local list_name="$3"
  local strategy_raw="$4"
  local dialer_type="$5"
  local strategy file
  local -a nodes

  file=$(resolve_list_file "${list_name}") || exit_error "负载均衡列表文件不存在: ${list_name}.txt"
  mapfile -t nodes < <(grep -vE '^[[:space:]]*(#|$)' "${file}")
  [[ ${#nodes[@]} -eq 0 ]] && exit_error "负载均衡列表为空: ${file}"

  strategy=$(normalize_strategy "${strategy_raw}")

  local service_name="service-${service_seq}"
  local chain_name="chain-${chain_seq}"
  local hop_name="hop-${hop_seq}"
  service_seq=$((service_seq + 1))
  chain_seq=$((chain_seq + 1))
  hop_seq=$((hop_seq + 1))

  {
    printf "  - name: %s\n" "${service_name}"
    printf "    addr: %s\n" "$(yaml_quote ":${listen_port}")"
    printf "    handler:\n"
    printf "      type: %s\n" "${proto}"
    printf "      chain: %s\n" "${chain_name}"
    printf "    listener:\n"
    printf "      type: %s\n" "${proto}"
  } >>"${services_tmp}"

  {
    printf "  - name: %s\n" "${chain_name}"
    printf "    hops:\n"
    printf "      - name: %s\n" "${hop_name}"
    printf "        selector:\n"
    printf "          strategy: %s\n" "${strategy}"
    printf "        nodes:\n"
    local node host addr
    for addr in "${nodes[@]}"; do
      host="${addr%%:*}"
      printf "          - name: node-%s\n" "${node_seq}"
      printf "            addr: %s\n" "$(yaml_quote "${addr}")"
      printf "            connector:\n"
      printf "              type: relay\n"
      printf "            dialer:\n"
      printf "              type: %s\n" "${dialer_type}"
      printf "              tls:\n"
      printf "                serverName: %s\n" "$(yaml_quote "${host}")"
      node_seq=$((node_seq + 1))
    done
  } >>"${chains_tmp}"
}

append_rule() {
  local rule_type="$1"
  local listen_value="$2"
  local target_value="$3"
  local extra_value="$4"
  local cipher
  local auth_mode username password cert_path key_path cert_kind

  case "${rule_type}" in
  nonencrypt)
    append_cli_fragment -L "tcp://:${listen_value}/${target_value}:${extra_value}"
    append_cli_fragment -L "udp://:${listen_value}/${target_value}:${extra_value}"
    ;;
  cdnno)
    append_cli_fragment -L "tcp://:${listen_value}/${target_value}?host=${extra_value}"
    append_cli_fragment -L "udp://:${listen_value}/${target_value}?host=${extra_value}"
    ;;
  encrypttls)
    append_cli_fragment -L "tcp://:${listen_value}" -F "relay+tls://${target_value}:${extra_value}"
    append_cli_fragment -L "udp://:${listen_value}" -F "relay+tls://${target_value}:${extra_value}"
    ;;
  encryptws)
    append_cli_fragment -L "tcp://:${listen_value}" -F "relay+ws://${target_value}:${extra_value}"
    append_cli_fragment -L "udp://:${listen_value}" -F "relay+ws://${target_value}:${extra_value}"
    ;;
  encryptwss)
    append_cli_fragment -L "tcp://:${listen_value}" -F "relay+wss://${target_value}:${extra_value}"
    append_cli_fragment -L "udp://:${listen_value}" -F "relay+wss://${target_value}:${extra_value}"
    ;;
  cdnws)
    append_cli_fragment -L "tcp://:${listen_value}" -F "relay+ws://${target_value}?host=${extra_value}"
    append_cli_fragment -L "udp://:${listen_value}" -F "relay+ws://${target_value}?host=${extra_value}"
    ;;
  cdnwss)
    append_cli_fragment -L "tcp://:${listen_value}" -F "relay+wss://${target_value}?host=${extra_value}"
    append_cli_fragment -L "udp://:${listen_value}" -F "relay+wss://${target_value}?host=${extra_value}"
    ;;
  decrypttls)
    if [[ -d "${HOME}/gost_cert" ]]; then
      append_cli_fragment -L "relay+tls://:${listen_value}/${target_value}:${extra_value}?cert=${HOME}/gost_cert/cert.pem&key=${HOME}/gost_cert/key.pem"
    else
      append_cli_fragment -L "relay+tls://:${listen_value}/${target_value}:${extra_value}"
    fi
    ;;
  decryptws)
    append_cli_fragment -L "relay+ws://:${listen_value}/${target_value}:${extra_value}"
    ;;
  decryptwss)
    if [[ -d "${HOME}/gost_cert" ]]; then
      append_cli_fragment -L "relay+wss://:${listen_value}/${target_value}:${extra_value}?cert=${HOME}/gost_cert/cert.pem&key=${HOME}/gost_cert/key.pem"
    else
      append_cli_fragment -L "relay+wss://:${listen_value}/${target_value}:${extra_value}"
    fi
    ;;
  ss)
    cipher=$(normalize_ss_cipher "${target_value}")
    append_cli_fragment -L "ss://${cipher}:${listen_value}@:${extra_value}"
    ;;
  socks)
    if [[ "${target_value}" == "__NOAUTH__" ]]; then
      append_cli_fragment -L "socks5://:${extra_value}"
    else
      append_cli_fragment -L "socks5://${target_value}:${listen_value}@:${extra_value}"
    fi
    ;;
  http)
    if [[ "${target_value}" == "__NOAUTH__" ]]; then
      append_cli_fragment -L "http://:${extra_value}"
    else
      append_cli_fragment -L "http://${target_value}:${listen_value}@:${extra_value}"
    fi
    ;;
  https)
    IFS='|' read -r auth_mode username password cert_path key_path cert_kind <<<"${target_value}"
    if [[ -z "${cert_path}" || -z "${key_path}" ]]; then
      exit_error "HTTPS 代理证书路径缺失: ${listen_value}/${extra_value}"
    fi
    if [[ "${auth_mode}" == "noauth" ]]; then
      append_cli_fragment -L "https://:${listen_value}?certFile=${cert_path}&keyFile=${key_path}"
    else
      append_cli_fragment -L "https://${username}:${password}@:${listen_value}?certFile=${cert_path}&keyFile=${key_path}"
    fi
    ;;
  peerno)
    append_direct_balance_service "tcp" "${listen_value}" "${target_value}" "${extra_value}"
    append_direct_balance_service "udp" "${listen_value}" "${target_value}" "${extra_value}"
    ;;
  peertls)
    append_chain_balance_service "tcp" "${listen_value}" "${target_value}" "${extra_value}" "tls"
    append_chain_balance_service "udp" "${listen_value}" "${target_value}" "${extra_value}" "tls"
    ;;
  peerws)
    append_chain_balance_service "tcp" "${listen_value}" "${target_value}" "${extra_value}" "ws"
    append_chain_balance_service "udp" "${listen_value}" "${target_value}" "${extra_value}" "ws"
    ;;
  peerwss)
    append_chain_balance_service "tcp" "${listen_value}" "${target_value}" "${extra_value}" "wss"
    append_chain_balance_service "udp" "${listen_value}" "${target_value}" "${extra_value}" "wss"
    ;;
  *)
    exit_error "未知配置类型: ${rule_type}"
    ;;
  esac
}

parse_rule_record() {
  local target_payload type_and_listen
  parsed_auth_mode="auth"
  parsed_cert_mode=""
  parsed_cert_domain=""
  parsed_cert_path=""
  parsed_key_path=""
  parsed_cert_kind=""
  parsed_listen_secret=""

  type_and_listen=${rule_record%%#*}
  parsed_listen_value=${type_and_listen#*/}
  parsed_rule_type=${type_and_listen%/*}

  if [[ "${parsed_rule_type}" == "https" ]]; then
    parsed_cert_domain=${rule_record#*#}
    parsed_cert_domain=${parsed_cert_domain%%#*}
    target_payload=${rule_record##*#}
    parsed_target_host="${parsed_cert_domain}"
    parsed_target_value="${target_payload}"
    IFS='|' read -r parsed_auth_mode parsed_target_host parsed_listen_secret parsed_cert_path parsed_key_path parsed_cert_kind <<<"${target_payload}"
    parsed_cert_mode="${parsed_cert_kind}"
    if [[ "${parsed_auth_mode}" == "noauth" ]]; then
      parsed_target_host=""
    fi
    return 0
  fi

  target_payload=${rule_record#*#}
  parsed_target_value=${target_payload#*#}
  parsed_target_host=${target_payload%#*}
  parsed_auth_mode="auth"

  if [[ "${parsed_rule_type}" == "socks" || "${parsed_rule_type}" == "http" ]]; then
    if [[ "${parsed_target_host}" == "__NOAUTH__" ]]; then
      parsed_auth_mode="noauth"
      parsed_target_host=""
    elif [[ "${parsed_target_value}" == "__NOAUTH__" ]]; then
      parsed_auth_mode="noauth"
      parsed_target_value="${parsed_target_host}"
      parsed_target_host=""
    fi
  elif [[ "${parsed_rule_type}" == "https" ]]; then
    IFS='|' read -r parsed_auth_mode parsed_target_host parsed_target_value parsed_cert_path parsed_key_path parsed_cert_kind <<<"${target_payload}"
    parsed_cert_mode="${parsed_cert_kind}"
    parsed_cert_domain="${parsed_target_host}"
  fi
}

render_config() {
  ensure_rawconf_file
  if [[ ! -x "${gost_bin}" ]]; then
    write_placeholder_config
    return 0
  fi

  services_tmp=$(mktemp)
  chains_tmp=$(mktemp)
  has_strategy_fallback=0

  while IFS= read -r trans_conf || [[ -n "${trans_conf}" ]]; do
    [[ -z "${trans_conf}" ]] && continue
    rule_record="${trans_conf}"
    parse_rule_record
    if [[ "${parsed_rule_type}" == "https" ]]; then
      append_rule "${parsed_rule_type}" "${parsed_listen_value}" "${parsed_target_value}" "${parsed_cert_domain}"
    else
      append_rule "${parsed_rule_type}" "${parsed_listen_value}" "${parsed_target_host}" "${parsed_target_value}"
    fi
  done <"${raw_conf_path}"

  if [[ ! -s "${services_tmp}" ]]; then
    write_placeholder_config
  else
    {
      printf "services:\n"
      cat "${services_tmp}"
      if [[ -s "${chains_tmp}" ]]; then
        printf "\nchains:\n"
        cat "${chains_tmp}"
      fi
    } >"${gost_conf_path}"
  fi

  rm -f "${services_tmp}" "${chains_tmp}"
  services_tmp=""
  chains_tmp=""

  if [[ ${has_strategy_fallback} -eq 1 ]]; then
    log_info "gost v3 不支持旧版 fifo 策略，已自动回退为 round。"
  fi
}

checknew() {
  local current_ver
  current_ver=$(current_gost_version)
  if [[ -z "${current_ver}" ]]; then
    log_error "未检测到已安装的 gost，改为执行安装流程。"
    Install_ct
    return
  fi

  echo "你当前的 gost 版本为: v${current_ver}"
  echo -n "是否更新到最新 v3 版本 (y/n): "
  read -r checknewnum
  if [[ ${checknewnum} == [Yy] ]]; then
    Install_ct
  fi
}

Install_ct() {
  check_root
  check_sys
  Installation_dependency
  check_file
  check_new_ver
  download_gost "${ct_new_ver}"
  write_service_file
  ensure_rawconf_file
  render_config
  systemctl daemon-reload
  systemctl enable gost >/dev/null 2>&1
  systemctl restart gost

  if [[ -x "${gost_bin}" && -f "${service_path}" && -f "${gost_conf_path}" ]]; then
    log_info "gost v${ct_new_ver} 安装完成"
  else
    exit_error "gost 安装未完成，请检查系统日志。"
  fi
}

Uninstall_ct() {
  check_root
  systemctl stop gost >/dev/null 2>&1 || true
  systemctl disable gost >/dev/null 2>&1 || true
  rm -f "${gost_bin}"
  rm -f "${service_path}"
  rm -rf /etc/gost
  systemctl daemon-reload
  log_info "gost 已卸载"
}

Start_ct() {
  check_root
  systemctl start gost
  log_info "已启动"
}

Stop_ct() {
  check_root
  systemctl stop gost
  log_info "已停止"
}

Restart_ct() {
  check_root
  render_config
  systemctl restart gost
  log_info "已重建 v3 配置并重启"
}

select_rule_type() {
  echo -e "请问您要设置哪种功能:"
  echo -e "-----------------------------------"
  echo -e "[1] tcp+udp 流量转发，不加密"
  echo -e "说明: 一般设置在中转机上"
  echo -e "-----------------------------------"
  echo -e "[2] 加密隧道流量转发"
  echo -e "说明: 用于中转到另一台 gost 落地机"
  echo -e "-----------------------------------"
  echo -e "[3] 解密由 gost 传输而来的流量并转发"
  echo -e "说明: 一般设置在落地机上"
  echo -e "-----------------------------------"
  echo -e "[4] 一键安装 ss/socks5/http/https 代理"
  echo -e "-----------------------------------"
  echo -e "[5] 进阶：多落地均衡负载"
  echo -e "-----------------------------------"
  echo -e "[6] 进阶：转发 CDN 自选节点"
  echo -e "-----------------------------------"
  read -r -p "请选择: " numprotocol

  case "${numprotocol}" in
  1)
    rule_type="nonencrypt"
    ;;
  2)
    select_encrypt_rule_type
    ;;
  3)
    select_decrypt_rule_type
    ;;
  4)
    select_proxy_rule_type
    ;;
  5)
    select_balance_rule_type
    ;;
  6)
    select_cdn_rule_type
    ;;
  *)
    exit_error "输入错误，请重试。"
    ;;
  esac
}

prompt_rule_listen_value() {
  if [[ "${rule_type}" == "ss" ]]; then
    read -r -p "请输入 ss 密码: " rule_listen_value
  elif [[ "${rule_type}" == "socks" ]]; then
    if [[ "${rule_auth_mode}" == "auth" ]]; then
      read -r -p "请输入 socks 密码: " rule_listen_value
    fi
  elif [[ "${rule_type}" == "http" ]]; then
    if [[ "${rule_auth_mode}" == "auth" ]]; then
      read -r -p "请输入 http 密码: " rule_listen_value
    fi
  elif [[ "${rule_type}" == "https" ]]; then
    if [[ "${rule_auth_mode}" == "auth" ]]; then
      read -r -p "请输入 https 密码: " rule_listen_value
    fi
  else
    echo -e "请问要监听哪个本地端口?"
    read -r -p "请输入: " rule_listen_value
  fi
}

prompt_rule_target_host() {
  if [[ "${rule_type}" == "ss" ]]; then
    echo -e "请选择 ss 加密方式:"
    echo -e "[1] aes-256-gcm"
    echo -e "[2] aes-256-cfb"
    echo -e "[3] chacha20-ietf-poly1305"
    echo -e "[4] chacha20"
    echo -e "[5] rc4-md5"
    echo -e "[6] 兼容旧版 AEAD_CHACHA20_POLY1305"
    read -r -p "请选择 ss 加密方式: " ssencrypt
    case "${ssencrypt}" in
    1) rule_target_host="aes-256-gcm" ;;
    2) rule_target_host="aes-256-cfb" ;;
    3) rule_target_host="chacha20-ietf-poly1305" ;;
    4) rule_target_host="chacha20" ;;
    5) rule_target_host="rc4-md5" ;;
    6) rule_target_host="AEAD_CHACHA20_POLY1305" ;;
    *) exit_error "输入错误，请重试。" ;;
    esac
  elif [[ "${rule_type}" == "socks" ]]; then
    if [[ "${rule_auth_mode}" == "auth" ]]; then
      read -r -p "请输入 socks 用户名: " rule_target_host
    else
      rule_target_host="__NOAUTH__"
    fi
  elif [[ "${rule_type}" == "http" ]]; then
    if [[ "${rule_auth_mode}" == "auth" ]]; then
      read -r -p "请输入 http 用户名: " rule_target_host
    else
      rule_target_host="__NOAUTH__"
    fi
  elif [[ "${rule_type}" == "https" ]]; then
    if [[ "${rule_auth_mode}" == "auth" ]]; then
      read -r -p "请输入 https 用户名: " rule_target_host
    else
      rule_target_host=""
    fi
  elif [[ "${rule_type}" == peer* ]]; then
    mkdir -p "${list_dir}"
    echo -e "请输入落地列表文件名（不含后缀）"
    read -r -e -p "例如 ips1、iplist2: " rule_target_host
    : >"${list_dir}/${rule_target_host}.txt"
    echo -e "请依次输入要均衡负载的落地 ip:端口"
    while true; do
      read -r -p "落地 IP 或域名: " peer_ip
      read -r -p "落地端口: " peer_port
      printf '%s\n' "${peer_ip}:${peer_port}" >>"${list_dir}/${rule_target_host}.txt"
      read -r -e -p "是否继续添加落地？[Y/n]: " addyn
      [[ -z ${addyn} ]] && addyn="y"
      if [[ ${addyn} == [Nn] ]]; then
        echo -e "已创建 ${list_dir}/${rule_target_host}.txt"
        break
      fi
    done
  elif [[ "${rule_type}" == cdn* ]]; then
    read -r -p "请输入 CDN 自选节点 IP: " rule_target_host
    echo -e "[1] 80"
    echo -e "[2] 443"
    echo -e "[3] 自定义端口"
    read -r -p "请选择端口: " cdnport
    case "${cdnport}" in
    1) rule_target_host="${rule_target_host}:80" ;;
    2) rule_target_host="${rule_target_host}:443" ;;
    3)
      read -r -p "请输入自定义端口: " customport
      rule_target_host="${rule_target_host}:${customport}"
      ;;
    *)
      exit_error "输入错误，请重试。"
      ;;
    esac
  else
    echo -e "请输入目标 IP 或域名"
    if [[ ${rule_tls_verify} == [Yy] ]]; then
      echo -e "注意: 已开启证书校验时，请务必填写域名"
    fi
    read -r -p "请输入: " rule_target_host
  fi
}

prompt_rule_target_value() {
  if [[ "${rule_type}" == "ss" ]]; then
    read -r -p "请输入 ss 代理服务端口: " rule_target_value
  elif [[ "${rule_type}" == "socks" ]]; then
    read -r -p "请输入 socks 代理服务端口: " rule_target_value
  elif [[ "${rule_type}" == "http" ]]; then
    read -r -p "请输入 http 代理服务端口: " rule_target_value
  elif [[ "${rule_type}" == "https" ]]; then
    read -r -p "请输入 https 代理服务端口: " rule_target_value
  elif [[ "${rule_type}" == peer* ]]; then
    echo -e "[1] round - 轮询"
    echo -e "[2] random - 随机"
    echo -e "[3] fifo - 旧版自上而下（v3 将回退为 round）"
    read -r -p "请选择均衡负载类型: " numstra
    case "${numstra}" in
    1) rule_target_value="round" ;;
    2) rule_target_value="random" ;;
    3) rule_target_value="fifo" ;;
    *) exit_error "输入错误，请重试。" ;;
    esac
  elif [[ "${rule_type}" == cdn* ]]; then
    read -r -p "请输入 host: " rule_target_value
  else
    read -r -p "请输入目标端口: " rule_target_value
    if [[ ${rule_tls_verify} == [Yy] ]]; then
      rule_target_value="${rule_target_value}?secure=true"
    fi
  fi
}

prompt_https_cert_mode() {
  echo -e "[1] 自动申请域名证书"
  echo -e "[2] 自动申请 IP 证书"
  echo -e "[3] 使用已有证书"
  read -r -p "请选择 HTTPS 证书方式: " rule_cert_mode

  case "${rule_cert_mode}" in
  1)
    prompt_domain_cert_context
    prompt_cert_issue_method
    issue_domain_cert
    ;;
  2)
    prompt_ip_cert_context
    issue_ip_cert
    ;;
  3)
    echo -e "[1] 域名证书"
    echo -e "[2] IP 证书"
    read -r -p "请选择已有证书类型: " existing_cert_kind
    case "${existing_cert_kind}" in
    1)
      rule_cert_kind="domain"
      read -r -p "请输入域名: " rule_cert_domain
      ;;
    2)
      rule_cert_kind="ip"
      read -r -p "请输入公网 IP: " rule_cert_domain
      ;;
    *)
      exit_error "输入错误，请重试。"
      ;;
    esac
    resolve_existing_cert_paths
    ;;
  *)
    exit_error "输入错误，请重试。"
    ;;
  esac
}

save_rule_record() {
  ensure_rawconf_file
  if [[ "${rule_type}" == "https" ]]; then
    printf '%s\n' "${rule_type}/${rule_target_value}#${rule_cert_domain}#${rule_auth_mode}|${rule_target_host}|${rule_listen_value}|${rule_cert_path}|${rule_key_path}|${rule_cert_kind}" >>"${raw_conf_path}"
  else
    printf '%s\n' "${rule_type}/${rule_listen_value}#${rule_target_host}#${rule_target_value}" >>"${raw_conf_path}"
  fi
}

add_rule_interactive() {
  reset_rule_context
  select_rule_type
  if [[ "${rule_flow_result}" != "add" ]]; then
    return 1
  fi
  prompt_rule_target_value
  if [[ "${rule_type}" == "https" ]]; then
    prompt_https_cert_mode
  fi
  prompt_rule_listen_value
  prompt_rule_target_host
  save_rule_record
}

rebuild_and_restart_gost() {
  render_config
  sync_ufw_ports
  systemctl restart gost
}

install_cert_dependencies() {
  check_sys
  if [[ ${release} == "centos" ]]; then
    yum install -y socat
  else
    apt-get install -y socat
  fi
}

ensure_acme_sh() {
  if [[ ! -x "${HOME}/.acme.sh/acme.sh" ]]; then
    curl https://get.acme.sh | sh
  fi
}

prompt_cert_issue_method() {
  echo -e "[1] HTTP 申请（80 端口需可用）"
  echo -e "[2] Cloudflare DNS API 申请"
  read -r -p "请选择证书申请方式: " rule_cert_method
}

prompt_domain_cert_context() {
  read -r -p "请输入 ZeroSSL 账户邮箱: " zeromail
  read -r -p "请输入解析到本机的域名: " rule_cert_domain
  rule_cert_kind="domain"
}

prompt_ip_cert_context() {
  read -r -p "请输入公网 IP: " rule_cert_domain
  rule_cert_kind="ip"
  rule_cert_method="1"
}

configure_acme_ca() {
  local server_name="$1"
  ensure_acme_sh
  "${HOME}"/.acme.sh/acme.sh --set-default-ca --server "${server_name}"
}

register_zerossl_account() {
  if [[ -n "${zeromail}" ]]; then
    "${HOME}"/.acme.sh/acme.sh --register-account -m "${zeromail}" --server zerossl
  fi
}

apply_cloudflare_env() {
  read -r -p "请输入 Cloudflare 账户邮箱: " cfmail
  read -r -p "请输入 Cloudflare Global API Key: " cfkey
  export CF_Key="${cfkey}"
  export CF_Email="${cfmail}"
}

issue_domain_cert() {
  local cert_dir
  cert_dir=$(cert_dir_for_kind "domain" "${rule_cert_domain}")
  mkdir -p "${cert_dir}"

  install_cert_dependencies
  ensure_http_challenge_port
  configure_acme_ca "zerossl"
  register_zerossl_account

  if [[ "${rule_cert_method}" == "1" ]]; then
    if ! "${HOME}"/.acme.sh/acme.sh --issue -d "${rule_cert_domain}" --standalone -k ec-256 --force; then
      exit_error "域名证书申请失败"
    fi
  elif [[ "${rule_cert_method}" == "2" ]]; then
    apply_cloudflare_env
    if ! "${HOME}"/.acme.sh/acme.sh --issue --dns dns_cf -d "${rule_cert_domain}" --standalone -k ec-256 --force; then
      exit_error "域名证书申请失败"
    fi
  else
    exit_error "未知域名证书申请方式"
  fi

  "${HOME}"/.acme.sh/acme.sh --installcert -d "${rule_cert_domain}" \
    --fullchainpath "${cert_dir}/cert.pem" \
    --keypath "${cert_dir}/key.pem" \
    --reloadcmd "systemctl restart gost" \
    --ecc --force

  rule_cert_path="${cert_dir}/cert.pem"
  rule_key_path="${cert_dir}/key.pem"
}

issue_ip_cert() {
  local cert_dir
  cert_dir=$(cert_dir_for_kind "ip" "${rule_cert_domain}")
  mkdir -p "${cert_dir}"

  install_cert_dependencies
  ensure_http_challenge_port
  configure_acme_ca "letsencrypt"

  if ! "${HOME}"/.acme.sh/acme.sh --issue --standalone -d "${rule_cert_domain}" --server letsencrypt --cert-profile shortlived --force; then
    exit_error "IP 证书申请失败"
  fi

  "${HOME}"/.acme.sh/acme.sh --installcert -d "${rule_cert_domain}" \
    --fullchainpath "${cert_dir}/cert.pem" \
    --keypath "${cert_dir}/key.pem" \
    --reloadcmd "systemctl restart gost" \
    --force

  rule_cert_path="${cert_dir}/cert.pem"
  rule_key_path="${cert_dir}/key.pem"
}

resolve_existing_cert_paths() {
  local cert_dir
  cert_dir=$(cert_dir_for_kind "${rule_cert_kind}" "${rule_cert_domain}")
  rule_cert_path="${cert_dir}/cert.pem"
  rule_key_path="${cert_dir}/key.pem"
  [[ -f "${rule_cert_path}" && -f "${rule_key_path}" ]] || exit_error "证书文件不存在: ${cert_dir}"
}

manage_proxy_rules() {
  local proxy_type="$1"
  local proxy_label
  local count_line i action selection raw_line
  local -a match_lines=()
  local -a match_ports=()
  local -a match_users=()
  local -a match_auth_modes=()
  local -a match_hosts=()
  local -a match_cert_kinds=()
  local -a match_records=()

  proxy_label=$(proxy_type_label "${proxy_type}")
  ensure_rawconf_file
  count_line=$(awk 'END{print NR}' "${raw_conf_path}")

  for ((i = 1; i <= count_line; i++)); do
    rule_record=$(sed -n "${i}p" "${raw_conf_path}")
    [[ -z "${rule_record}" ]] && continue
    parse_rule_record
    [[ "${parsed_rule_type}" != "${proxy_type}" ]] && continue
    match_lines+=("${i}")
    match_records+=("${rule_record}")
    if [[ "${proxy_type}" == "https" ]]; then
      match_ports+=("${parsed_listen_value}")
      match_users+=("${parsed_target_host}")
      match_hosts+=("${parsed_cert_domain}")
      match_cert_kinds+=("${parsed_cert_kind}")
    else
      match_ports+=("${parsed_target_value}")
      match_users+=("${parsed_target_host}")
    fi
    match_auth_modes+=("${parsed_auth_mode}")
  done

  if [[ ${#match_lines[@]} -eq 0 ]]; then
    log_info "当前没有 ${proxy_label} 代理规则"
    return 0
  fi

  echo -e "                 ${proxy_label} 代理管理"
  echo -e "--------------------------------------------------------"
  if [[ "${proxy_type}" == "https" ]]; then
    echo -e "序号|监听端口\t|绑定\t|认证\t|用户名\t|证书类型"
  else
    echo -e "序号|监听端口\t|认证\t|用户名"
  fi
  echo -e "--------------------------------------------------------"
  for i in "${!match_lines[@]}"; do
    if [[ "${proxy_type}" == "https" ]]; then
      if [[ "${match_auth_modes[$i]}" == "noauth" ]]; then
        echo -e " $((i + 1))  |${match_ports[$i]}\t|${match_hosts[$i]}\t|无认证\t|-\t|${match_cert_kinds[$i]}"
      else
        echo -e " $((i + 1))  |${match_ports[$i]}\t|${match_hosts[$i]}\t|有认证\t|${match_users[$i]}\t|${match_cert_kinds[$i]}"
      fi
    else
      if [[ "${match_auth_modes[$i]}" == "noauth" ]]; then
        echo -e " $((i + 1))  |${match_ports[$i]}\t|无认证\t|-"
      else
        echo -e " $((i + 1))  |${match_ports[$i]}\t|有认证\t|${match_users[$i]}"
      fi
    fi
    echo -e "--------------------------------------------------------"
  done

  if [[ "${proxy_type}" == "https" ]]; then
    echo -e "[1] 删除代理"
    echo -e "[2] 重新申请证书"
    echo -e "[3] 返回"
  else
    echo -e "[1] 删除代理"
    echo -e "[2] 返回"
  fi
  read -r -p "请选择: " action

  case "${action}" in
  1)
    read -r -p "请输入要删除的代理序号: " selection
    if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#match_lines[@]})); then
      exit_error "请输入正确的代理序号。"
    fi
    raw_line=${match_lines[$((selection - 1))]}
    sed -i "${raw_line}d" "${raw_conf_path}"
    rebuild_and_restart_gost
    log_info "${proxy_label} 代理已删除"
    ;;
  2)
    if [[ "${proxy_type}" == "https" ]]; then
      read -r -p "请输入要重新申请证书的代理序号: " selection
      if [[ ! "${selection}" =~ ^[0-9]+$ ]] || ((selection < 1 || selection > ${#match_lines[@]})); then
        exit_error "请输入正确的代理序号。"
      fi
      rule_record="${match_records[$((selection - 1))]}"
      parse_rule_record
      rule_cert_domain="${parsed_cert_domain}"
      rule_cert_kind="${parsed_cert_kind}"
      if [[ "${rule_cert_kind}" == "domain" ]]; then
        prompt_cert_issue_method
        issue_domain_cert
      else
        issue_ip_cert
      fi
      raw_line=${match_lines[$((selection - 1))]}
      if [[ "${parsed_auth_mode}" == "noauth" ]]; then
        sed -i "${raw_line}c\\https/${parsed_listen_value}#${rule_cert_domain}#noauth|||${rule_cert_path}|${rule_key_path}|${rule_cert_kind}" "${raw_conf_path}"
      else
        sed -i "${raw_line}c\\https/${parsed_listen_value}#${rule_cert_domain}#auth|${parsed_target_host}|${parsed_listen_secret}|${rule_cert_path}|${rule_key_path}|${rule_cert_kind}" "${raw_conf_path}"
      fi
      rebuild_and_restart_gost
      log_info "https 代理证书已重新申请"
    else
      log_info "已返回 ${proxy_label} 管理菜单"
    fi
    ;;
  3)
    if [[ "${proxy_type}" == "https" ]]; then
      log_info "已返回 ${proxy_label} 管理菜单"
    else
      exit_error "输入错误，请重试。"
    fi
    ;;
  *)
    exit_error "输入错误，请重试。"
    ;;
  esac
}

select_proxy_action() {
  local proxy_type="$1"
  local proxy_label action auth_action

  proxy_label=$(rule_type_label "${proxy_type}")
  echo -e "[1] 添加代理"
  echo -e "[2] 管理代理"
  read -r -p "请选择 ${proxy_label} 操作: " action

  case "${action}" in
  1)
    if [[ "${proxy_type}" != "ss" ]]; then
      echo -e "[1] 无认证"
      echo -e "[2] 有认证"
      read -r -p "请选择 ${proxy_label} 认证模式: " auth_action
      case "${auth_action}" in
      1) rule_auth_mode="noauth" ;;
      2) rule_auth_mode="auth" ;;
      *) exit_error "输入错误，请重试。" ;;
      esac
    fi
    rule_type="${proxy_type}"
    rule_flow_result="add"
    ;;
  2)
    manage_proxy_rules "${proxy_type}"
    rule_flow_result="managed"
    ;;
  *)
    exit_error "输入错误，请重试。"
    ;;
  esac
}

select_encrypt_rule_type() {
  echo -e "[1] tls 隧道"
  echo -e "[2] ws 隧道"
  echo -e "[3] wss 隧道"
  echo -e "注意: 同一则转发，中转与落地传输类型必须对应。"
  read -r -p "请选择转发传输类型: " numencrypt

  case "${numencrypt}" in
  1)
    rule_type="encrypttls"
    read -r -e -p "落地机是否开启了自定义 tls 证书校验？[y/n]: " rule_tls_verify
    ;;
  2)
    rule_type="encryptws"
    ;;
  3)
    rule_type="encryptwss"
    read -r -e -p "落地机是否开启了自定义 tls 证书校验？[y/n]: " rule_tls_verify
    ;;
  *)
    exit_error "输入错误，请重试。"
    ;;
  esac
}

select_balance_rule_type() {
  echo -e "[1] 不加密转发"
  echo -e "[2] tls 隧道"
  echo -e "[3] ws 隧道"
  echo -e "[4] wss 隧道"
  echo -e "此功能已映射到 gost v3 的 selector + nodes。"
  read -r -p "请选择均衡负载传输类型: " numpeer

  case "${numpeer}" in
  1) rule_type="peerno" ;;
  2) rule_type="peertls" ;;
  3) rule_type="peerws" ;;
  4) rule_type="peerwss" ;;
  *) exit_error "输入错误，请重试。" ;;
  esac
}

select_cdn_rule_type() {
  echo -e "[1] 不加密转发"
  echo -e "[2] ws 隧道"
  echo -e "[3] wss 隧道"
  read -r -p "请选择 CDN 转发传输类型: " numcdn

  case "${numcdn}" in
  1) rule_type="cdnno" ;;
  2) rule_type="cdnws" ;;
  3) rule_type="cdnwss" ;;
  *) exit_error "输入错误，请重试。" ;;
  esac
}

cert() {
  reset_rule_context
  echo -e "[1] 自动申请域名证书"
  echo -e "[2] 自动申请 IP 证书（Let\\'s Encrypt shortlived）"
  echo -e "[3] 手动上传证书"
  read -r -p "请选择证书生成方式: " numcert

  if [[ "${numcert}" == "1" ]]; then
    prompt_domain_cert_context
    prompt_cert_issue_method
    issue_domain_cert
    log_info "域名证书已准备完成: ${rule_cert_path}"
  elif [[ "${numcert}" == "2" ]]; then
    prompt_ip_cert_context
    issue_ip_cert
    log_info "IP 证书已准备完成: ${rule_cert_path}"
  elif [[ "${numcert}" == "3" ]]; then
    echo -e "[1] 域名证书目录"
    echo -e "[2] IP 证书目录"
    read -r -p "请选择手动证书类型: " manual_kind
    case "${manual_kind}" in
    1)
      rule_cert_kind="domain"
      read -r -p "请输入域名: " rule_cert_domain
      ;;
    2)
      rule_cert_kind="ip"
      read -r -p "请输入公网 IP: " rule_cert_domain
      ;;
    *)
      exit_error "输入错误，请重试。"
      ;;
    esac
    mkdir -p "$(cert_dir_for_kind "${rule_cert_kind}" "${rule_cert_domain}")"
    echo -e "请将 cert.pem 与 key.pem 上传到: $(cert_dir_for_kind "${rule_cert_kind}" "${rule_cert_domain}")"
  else
    exit_error "输入错误，请重试。"
  fi
}

select_decrypt_rule_type() {
  echo -e "[1] tls"
  echo -e "[2] ws"
  echo -e "[3] wss"
  read -r -p "请选择解密传输类型: " numdecrypt

  case "${numdecrypt}" in
  1) rule_type="decrypttls" ;;
  2) rule_type="decryptws" ;;
  3) rule_type="decryptwss" ;;
  *) exit_error "输入错误，请重试。" ;;
  esac
}

select_proxy_rule_type() {
  echo -e "[1] shadowsocks"
  echo -e "[2] socks5"
  echo -e "[3] http"
  echo -e "[4] https"
  read -r -p "请选择代理类型: " numproxy

  case "${numproxy}" in
  1) rule_type="ss" ;;
  2) select_proxy_action "socks" ;;
  3) select_proxy_action "http" ;;
  4) select_proxy_action "https" ;;
  *) exit_error "输入错误，请重试。" ;;
  esac
}

show_all_conf() {
  ensure_rawconf_file
  if [[ ! -s "${raw_conf_path}" ]]; then
    echo -e "当前没有保存的规则，运行中的 v3 配置为占位配置。"
    return 0
  fi

  echo -e "                      GOST 规则                        "
  echo -e "--------------------------------------------------------"
  echo -e "序号|方法\t\t|本地端口\t|目的地地址:目的地端口"
  echo -e "--------------------------------------------------------"

  local count_line i str
  count_line=$(awk 'END{print NR}' "${raw_conf_path}")
  for ((i = 1; i <= count_line; i++)); do
    rule_record=$(sed -n "${i}p" "${raw_conf_path}")
    parse_rule_record

    case "${parsed_rule_type}" in
    nonencrypt) str="不加密中转" ;;
    encrypttls) str="tls 隧道" ;;
    encryptws) str="ws 隧道" ;;
    encryptwss) str="wss 隧道" ;;
    peerno) str="不加密均衡负载" ;;
    peertls) str="tls 均衡负载" ;;
    peerws) str="ws 均衡负载" ;;
    peerwss) str="wss 均衡负载" ;;
    decrypttls) str="tls 解密" ;;
    decryptws) str="ws 解密" ;;
    decryptwss) str="wss 解密" ;;
    ss) str="ss" ;;
    socks) str="socks5" ;;
    http) str="http" ;;
    https) str="https" ;;
    cdnno) str="CDN 不加密" ;;
    cdnws) str="CDN ws" ;;
    cdnwss) str="CDN wss" ;;
    *) str="未知" ;;
    esac

    if [[ "${parsed_rule_type}" == "https" ]]; then
      echo -e " ${i}  |${str}\t|${parsed_listen_value}\t|${parsed_cert_domain}:${parsed_cert_kind}"
    else
      echo -e " ${i}  |${str}\t|${parsed_listen_value}\t|${parsed_target_host}:${parsed_target_value}"
    fi
    echo -e "--------------------------------------------------------"
  done
}

cron_restart() {
  check_root
  echo -e "[1] 配置 gost 定时重启任务"
  echo -e "[2] 删除 gost 定时重启任务"
  read -r -p "请选择: " numcron

  if [[ "${numcron}" == "1" ]]; then
    echo -e "[1] 每 ? 小时重启"
    echo -e "[2] 每日 ? 点重启"
    read -r -p "请选择: " numcrontype
    sed -i '/systemctl restart gost/d' /etc/crontab
    if [[ "${numcrontype}" == "1" ]]; then
      read -r -p "每 ? 小时重启: " cronhr
      printf '0 */%s * * * root systemctl restart gost\n' "${cronhr}" >>/etc/crontab
      log_info "定时重启设置成功"
    elif [[ "${numcrontype}" == "2" ]]; then
      read -r -p "每日 ? 点重启: " cronhr
      printf '0 %s * * * root systemctl restart gost\n' "${cronhr}" >>/etc/crontab
      log_info "定时重启设置成功"
    else
      exit_error "输入错误，请重试。"
    fi
  elif [[ "${numcron}" == "2" ]]; then
    sed -i '/systemctl restart gost/d' /etc/crontab
    log_info "定时重启任务删除完成"
  else
    exit_error "输入错误，请重试。"
  fi
}

update_sh() {
  local ol_version
  ol_version=$(curl -L -s --connect-timeout 5 "${self_update_url}" | grep "shell_version=" | head -1 | awk -F '=|"' '{print $3}')
  if [[ -n "${ol_version}" ]]; then
    if [[ "${shell_version}" != "${ol_version}" ]]; then
      echo -e "存在新版本脚本，是否更新 [Y/N]?"
      read -r update_confirm
      case "${update_confirm}" in
      [yY] | [yY][eE][sS])
        curl -fsSL "${self_update_url}" -o ./gost.sh
        chmod +x ./gost.sh
        echo -e "更新完成"
        exit 0
        ;;
      *)
        ;;
      esac
    else
      echo -e "                 ${Green_font_prefix}当前脚本已是最新版本${Font_color_suffix}"
    fi
  else
    echo -e "                 ${Red_font_prefix}脚本最新版本获取失败，请检查与 GitHub 的连接${Font_color_suffix}"
  fi
}

main_menu() {
  update_sh
  echo
  echo -e "                 gost v3 一键安装配置脚本${Red_font_prefix}[${shell_version}]${Font_color_suffix}"
  echo "  ----------- KANIKIG -----------"
  echo "  特性: (1) 使用 gost v3 官方发布版"
  echo "        (2) 使用 systemd + YAML 配置进行管理"
  echo "        (3) 兼容旧版 rawconf 规则并渲染为 v3 配置"
  echo "  官方文档: https://gost.run"
  echo
  echo -e " ${Green_font_prefix}1.${Font_color_suffix} 安装 gost v3"
  echo -e " ${Green_font_prefix}2.${Font_color_suffix} 更新 gost"
  echo -e " ${Green_font_prefix}3.${Font_color_suffix} 卸载 gost"
  echo " ----------------------------"
  echo -e " ${Green_font_prefix}4.${Font_color_suffix} 启动 gost"
  echo -e " ${Green_font_prefix}5.${Font_color_suffix} 停止 gost"
  echo -e " ${Green_font_prefix}6.${Font_color_suffix} 重启 gost"
  echo " ----------------------------"
  echo -e " ${Green_font_prefix}7.${Font_color_suffix} 新增 gost 转发配置"
  echo -e " ${Green_font_prefix}8.${Font_color_suffix} 查看现有 gost 规则"
  echo -e " ${Green_font_prefix}9.${Font_color_suffix} 删除一则 gost 规则"
  echo " ----------------------------"
  echo -e " ${Green_font_prefix}10.${Font_color_suffix} gost 定时重启配置"
  echo -e " ${Green_font_prefix}11.${Font_color_suffix} 自定义 TLS 证书配置"
  echo
}

main() {
  if [[ -z "$(current_gost_version)" ]]; then
    Install_ct
    return 0
  fi

  main_menu
  read -r -e -p " 请输入数字 [1-11]: " num
  case "${num}" in
  1)
    Install_ct
    ;;
  2)
    checknew
    ;;
  3)
    Uninstall_ct
    ;;
  4)
    Start_ct
    ;;
  5)
    Stop_ct
    ;;
  6)
    Restart_ct
    ;;
  7)
    if add_rule_interactive; then
      rebuild_and_restart_gost
      echo -e "配置已生效，当前规则如下"
      show_all_conf
    elif [[ "${rule_flow_result}" == "managed" ]]; then
      echo -e "代理管理完成，当前规则如下"
      show_all_conf
    fi
    ;;
  8)
    show_all_conf
    ;;
  9)
    show_all_conf
    read -r -p "请输入要删除的配置编号: " numdelete
    if [[ "${numdelete}" =~ ^[0-9]+$ ]]; then
      sed -i "${numdelete}d" "${raw_conf_path}"
      rebuild_and_restart_gost
      log_info "规则已删除，服务已重启"
    else
      exit_error "请输入正确的数字。"
    fi
    ;;
  10)
    cron_restart
    ;;
  11)
    cert
    ;;
  *)
    exit_error "请输入正确数字 [1-11]。"
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
