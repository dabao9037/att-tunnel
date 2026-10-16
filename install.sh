#!/usr/bin/env bash
# att-tunnel — AT&T 线路丢包根治：Xray VLESS Reverse 反向隧道一键部署
# 不绑域名，B 端直连 A 的公网 IP；B 换 IP 自动重连。
set -Eeuo pipefail
# head 提前关管道会让上游收到 SIGPIPE(141)，配合 pipefail+set -e 会静默退出。
# 下面统一用 sed -n / awk NR 代替 head；再加个 ERR 提示，万一意外退出至少知道是哪一行。
trap 'rc=$?; echo "[X] 脚本在第 $LINENO 行意外退出 (rc=$rc)" >&2' ERR

VERSION="2.2.0"
XRAY_BIN="/usr/local/bin/xray"
# 独立配置 + 独立 systemd 服务，不碰机器上已有的 xray / 3x-ui / NodeLite
CFG_DIR="/usr/local/etc/att-tunnel"
CFG="$CFG_DIR/config.json"
SVC="att-tunnel"
STATE="/etc/att-tunnel"
TUNNEL_DOMAIN="tunnel.internal"
REVERSE_STYLE="new"   # 由 install_xray 实测覆盖：new=VLESS Reverse Proxy / old=顶层 reverse
# 固定 Xray 版本：26.7 及以后的版本有 bug，钉在 2026 年 6 月最后一版。
# 需要时可用 ATT_XRAY_VER 覆盖（例：ATT_XRAY_VER=v26.6.22）。
XRAY_VER="${ATT_XRAY_VER:-v26.6.27}"
# 用户入口传输方式：raw（默认，兼容所有客户端）| xhttp（伪装更好，但要求客户端支持）
# 客户端若不支持/未正确配置 XHTTP，会报 unexpected response version ... actually 72
# （72 = 'H'，VLESS 层收到明文 HTTP）。所以默认用 raw。
ATT_TRANSPORT="${ATT_TRANSPORT:-raw}"

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; BLD=$'\033[1m'; RST=$'\033[0m'
info(){ echo "${CYN}==>${RST} $*"; }
ok(){   echo "${GRN}[OK]${RST} $*"; }
warn(){ echo "${YEL}[!]${RST} $*"; }
die(){  echo "${RED}[X]${RST} $*" >&2; exit 1; }

need_root(){ [ "$(id -u)" = 0 ] || die "请用 root 运行"; }

# 非交互模式（网页面板调用 / 自动化）：ATT_NONINTERACTIVE=1，所有 read 改用环境变量或默认值
noninteractive(){ [ "${ATT_NONINTERACTIVE:-0}" = 1 ]; }

# 改配置的操作全局串行：面板和终端同时加/删节点时，后来者等最多 120 秒
cfg_lock(){
  [ -n "${ATT_CFG_LOCKED:-}" ] && return 0
  mkdir -p /run/lock 2>/dev/null || true
  exec 9>/run/lock/att-tunnel.lock
  flock -w 120 9 || die "另一个加/删节点操作正在进行，请稍后再试"
  ATT_CFG_LOCKED=1
}

# ---------- 依赖 ----------
install_deps(){
  local miss=()
  for c in curl unzip openssl; do command -v "$c" >/dev/null || miss+=("$c"); done
  [ ${#miss[@]} -eq 0 ] && return 0
  info "安装依赖: ${miss[*]}"
  if command -v apt-get >/dev/null; then
    apt-get update -qq && apt-get install -y -qq "${miss[@]}"
  elif command -v dnf >/dev/null; then dnf install -y -q "${miss[@]}"
  elif command -v yum >/dev/null; then yum install -y -q "${miss[@]}"
  else die "无法自动安装依赖，请手动安装: ${miss[*]}"; fi
}

# 探测该 Xray 用哪一代 reverse 语法：
#   new = VLESS Reverse Proxy（user 内 "reverse":{"tag"}），26.4+ 起强制
#   old = 顶层 "reverse":{portals/bridges}
# 判别用 simplified outbound style：旧版会因 "vnext" is empty 直接失败。
detect_reverse_style(){
  local probe; probe=$(mktemp --suffix=.json)
  cat > "$probe" <<'PROBE'
{ "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "tag": "t", "protocol": "vless",
      "settings": { "address": "127.0.0.1", "port": 12345,
        "id": "11111111-1111-1111-1111-111111111111", "encryption": "none",
        "reverse": { "tag": "bridge" } },
      "streamSettings": { "network": "raw" } },
    { "tag": "f", "protocol": "freedom" } ],
  "routing": { "rules": [ { "type": "field", "inboundTag": [ "bridge" ], "outboundTag": "f" } ] } }
PROBE
  if "$XRAY_BIN" -test -config "$probe" >/dev/null 2>&1; then
    REVERSE_STYLE=new
  else
    REVERSE_STYLE=old
  fi
  rm -f "$probe"
  ok "reverse 语法：$REVERSE_STYLE"
}

install_xray(){
  # 本工具专用副本固定用 $XRAY_VER，绝不复用机器上别的版本。
  # 原因：A/B 两端 Xray 版本不一致会导致握手失败，客户端报
  #   unknown version: 72  （72 = 'H'，即收到明文 HTTP 而非 VLESS）
  # 所以只认 /usr/local/bin/xray，且版本号必须等于 $XRAY_VER。
  local want="${XRAY_VER#v}"
  local cur=""
  if [ -x /usr/local/bin/xray ]; then
    cur=$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}')
  fi

  if [ -n "$cur" ] && [ "$cur" = "$want" ]; then
    XRAY_BIN="/usr/local/bin/xray"
    ok "专用 Xray 已是 $cur（$XRAY_BIN）"
    detect_reverse_style
    return 0
  fi

  if [ -n "$cur" ]; then
    warn "专用 Xray 版本是 $cur，需要 $want —— 卸载重装"
    systemctl stop "$SVC" 2>/dev/null || true
    rm -f /usr/local/bin/xray
  fi

  # 提示一下机器上别的 xray，但明确不碰它
  local other p
  for p in /opt/nodelite/bin/xray /usr/bin/xray /opt/xray/xray \
           /usr/local/x-ui/bin/xray-linux-amd64 /etc/x-ui/bin/xray-linux-amd64; do
    [ -x "$p" ] && { other="$p"; break; }
  done
  if [ -n "${other:-}" ]; then
    local ov; ov=$("$other" version 2>/dev/null | awk 'NR==1{print $2}')
    info "检测到其他 Xray：$other（$ov）—— 不使用、不修改它"
  fi

  info "安装专用 Xray-core $XRAY_VER 到 /usr/local/bin/xray ..."
  # 不用官方安装脚本：它会 stop/接管 xray.service，在已有面板的机器上会出问题，
  # 而且可能装比现有版本更旧的版。直接拉 latest 二进制。
  local arch tmpd
  case "$(uname -m)" in
    x86_64|amd64)  arch=64 ;;
    aarch64|arm64) arch=arm64-v8a ;;
    armv7l)        arch=arm32-v7a ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
  tmpd=$(mktemp -d)
  local url="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VER/Xray-linux-$arch.zip"
  if ! curl -fsSL --max-time 180 -o "$tmpd/x.zip" "$url"; then
    rm -rf "$tmpd"
    echo "下载失败：$url"
    echo "常见原因：GitHub 不可达（curl -I https://github.com）/ 硬盘满（df -h）"
    die "Xray 下载失败"
  fi
  if ! unzip -oq "$tmpd/x.zip" -d "$tmpd"; then
    rm -rf "$tmpd"; die "解包失败（缺 unzip？）"
  fi
  [ -f "$tmpd/xray" ] || { rm -rf "$tmpd"; die "包里没找到 xray 二进制"; }
  install -m 755 "$tmpd/xray" /usr/local/bin/xray
  mkdir -p /usr/local/share/xray
  for f in geoip.dat geosite.dat; do
    [ -f "$tmpd/$f" ] && install -m 644 "$tmpd/$f" "/usr/local/share/xray/$f"
  done
  rm -rf "$tmpd"
  XRAY_BIN="/usr/local/bin/xray"
  [ -x "$XRAY_BIN" ] || die "安装后未找到 $XRAY_BIN"
  ok "Xray 已安装: $("$XRAY_BIN" version | sed -n 1p)"

  detect_reverse_style
}

# ---------- 回落域名：实测可用才用（文档坑：microsoft 在新版会握手失败） ----------
# 与 NodeLite 保持一致的预置列表（NodeLite 默认 www.atlasobscura.com）。
# 已逐个做过真实 REALITY 握手实测（Xray 26.3.27），
# NodeLite 预置中的 www.hkstp.org 实测不通，故不纳入。
# 伪装域名列表：域名 | 国家
CANDIDATES_WITH_COUNTRY=(
  "www.atlasobscura.com|美国"
  "www.backblaze.com|美国"
  "www.gog.com|波兰"
  "www.cern.ch|瑞士"
  "www.sciencemuseum.org.uk|英国"
  "www.visitsingapore.com|新加坡"
  "www.discoverhongkong.com|中国香港"
  "www.a-star.edu.sg|新加坡"
  "www.animatetimes.com|日本"
  "www.famitsu.com|日本"
  "www.jodrellbank.net|英国"
)

# 提取纯域名列表（向后兼容）
CANDIDATES=()
for entry in "${CANDIDATES_WITH_COUNTRY[@]}"; do
  CANDIDATES+=("${entry%%|*}")
done

# 单个域名 TLS 1.3 实测
sni_ok(){
  timeout 8 openssl s_client -connect "$1:443" -tls1_3 -servername "$1" </dev/null 2>/dev/null \
    | grep -q 'TLSv1.3'
}

# 交互式选择伪装域名。
# 结果写入全局变量 SNI_PICKED，不走 $(...) 捕获：
# 之前用 sni=$(pick_sni_interactive)，列表/提示一旦混进 stdout 就被吞进 sni，
# 表现为“先出提示、选完才出列表”，并把多行文本写进 config.json 导致 xray 报
# invalid character '\n' in string literal。
SNI_PICKED=""
pick_sni_interactive(){
  SNI_PICKED=""
  local i d country choice usable=()
  echo
  echo "${CYN}===== 伪装域名（逐个实测 TLS 1.3，约需几秒）=====${RST}"
  for i in "${!CANDIDATES_WITH_COUNTRY[@]}"; do
    d="${CANDIDATES_WITH_COUNTRY[$i]%%|*}"
    country="${CANDIDATES_WITH_COUNTRY[$i]##*|}"
    printf "  %2d. %-30s [%s] " $((i+1)) "$d" "$country"
    if sni_ok "$d"; then
      printf "%s\n" "${GRN}可用${RST}"
      usable+=($((i+1)))
    else
      printf "%s\n" "${RED}不可用${RST}"
    fi
  done
  echo "${CYN}==============================================${RST}"
  echo "${YEL}提示：选入口服务器(A)所在国家/地区的网站，伪装效果更好${RST}"
  [ ${#usable[@]} -gt 0 ] || return 1

  while true; do
    read -r -p "请选择伪装域名序号 [回车默认 ${usable[0]}]: " choice || return 1
    [ -z "$choice" ] && choice="${usable[0]}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [[ " ${usable[*]} " == *" $choice "* ]]; then
      SNI_PICKED="${CANDIDATES_WITH_COUNTRY[$((choice-1))]%%|*}"
      return 0
    fi
    warn "无效选择，请输入上面标“可用”的序号"
  done
}

pick_sni(){
  # 手动指定优先：ATT_SNI=www.example.com
  if [ -n "${ATT_SNI:-}" ]; then
    if sni_ok "$ATT_SNI"; then
      echo "$ATT_SNI"; return 0
    fi
    warn "指定的 $ATT_SNI 不支持 TLS 1.3，改用预置列表" >&2
  fi
  local d
  for d in "${CANDIDATES[@]}"; do
    if sni_ok "$d"; then
      echo "$d"; return 0
    fi
  done
  return 1
}

# ---------- 工具 ----------
free_port(){
  local p
  while :; do
    p=$(( RANDOM % 40000 + 20000 ))
    ss -ltn 2>/dev/null | grep -q ":$p " || { echo "$p"; return; }
  done
}

pubip(){
  # 允许手动指定，避免探测失败卡住
  if [ -n "${ATT_IP:-}" ]; then printf '%s' "$ATT_IP"; return 0; fi
  curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null \
    || curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null \
    || curl -fsS --max-time 10 https://icanhazip.com 2>/dev/null
}

# 建立独立 systemd 服务（不动官方 xray.service）
write_unit(){
  cat > "/etc/systemd/system/$SVC.service" <<EOF
[Unit]
Description=att-tunnel (Xray VLESS Reverse)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -config $CFG
Restart=always
RestartSec=5
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# 原子写入 + 配置校验，失败自动还原
apply_cfg(){
  local new="$1"
  mkdir -p "$CFG_DIR"
  if [ -f "$CFG" ]; then
    cp "$CFG" "$CFG.bak-$(date +%Y%m%d%H%M%S)"
  fi
  "$XRAY_BIN" -test -config "$new" >/dev/null 2>&1 || {
    echo "--- 配置校验输出 ---"; "$XRAY_BIN" -test -config "$new" 2>&1 | tail -5
    die "配置校验未通过，已保留原配置"
  }
  mv "$new" "$CFG"
  chmod 644 "$CFG"
  chown root:root "$CFG"
  write_unit
  systemctl enable "$SVC" >/dev/null 2>&1 || true
  systemctl restart "$SVC"
  sleep 2
  systemctl is-active --quiet "$SVC" || {
    local bak; bak=$(ls -t "$CFG".bak-* 2>/dev/null | sed -n 1p)
    [ -n "$bak" ] && { cp "$bak" "$CFG"; systemctl restart "$SVC"; }
    echo "--- 服务日志 ---"; journalctl -u "$SVC" -n 15 --no-pager 2>&1 | tail -10
    die "启动失败，已回滚"
  }
  ok "配置已生效，$SVC 运行中（独立服务，未动你现有 xray）"
}

harden_service(){
  : # 自我12服务 unit 里已包含 Restart=always / RestartSec=5
}

# A 侧必需：B 换 IP 后会留下一条僵死隧道，portal 仍会往里派流量，
# 导致部分请求挂死。内核默认 tcp_retries2=15（约 15 分钟）太长，
# 调到 5（约 20 秒）才能快速回收。实测：调之前 6/8，调之后 10/10。
tune_tcp(){
  local f=/etc/sysctl.d/99-att-tunnel.conf
  cat > "$f" <<'EOF'
# att-tunnel: 快速回收死掉的反向隧道连接（B 换 IP / 断网场景）
net.ipv4.tcp_retries2 = 5
EOF
  sysctl -p "$f" >/dev/null 2>&1 && ok "已调优 tcp_retries2=5（僵死隧道 ~20s 回收）" \
    || warn "sysctl 应用失败，僵死连接回收会变慢"
}

open_fw(){
  local p="$1" done_any=0
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q 'Status: active'; then
    ufw allow "$p/tcp" >/dev/null 2>&1 && { ok "ufw 已放行 $p/tcp"; done_any=1; }
  fi
  if command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1 && { ok "firewalld 已放行 $p/tcp"; done_any=1; }
  fi
  # 很多 VPS 没有 ufw/firewalld，但 iptables INPUT 默认 DROP 或有拦截规则。
  # 上一版只看 ufw/firewalld，所以反代端口实际被 iptables 拦掉。
  if command -v iptables >/dev/null 2>&1; then
    local pol; pol=$(iptables -L INPUT -n 2>/dev/null | sed -n 1p)
    if echo "$pol" | grep -q 'policy DROP' || iptables -L INPUT -n 2>/dev/null | grep -qE '^(DROP|REJECT)'; then
      if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
        iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null \
          && { ok "iptables 已放行 $p/tcp"; done_any=1; }
      else
        ok "iptables 已有 $p/tcp 放行规则"; done_any=1
      fi
      # 尽力持久化
      if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1 || true
      elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
      fi
    fi
  fi
  [ "$done_any" = 1 ] || warn "本机未发现防火墙拦截"
  warn "❗ 云厂商安全组需你自己在控制台放行 $p/tcp（脚本改不了）"
}

# ================= 服务器 A：用户入口 + portal =================
deploy_a(){
  need_root; install_deps; install_xray


  local uport="${ATT_PORT:-443}"
  case "$uport" in (*[!0-9]*) die "ATT_PORT 必须是数字";; esac

  local aip; aip=$(pubip) || true
  if [ -z "${aip:-}" ]; then
    echo
    echo "${RED}无法获取本机公网 IP${RST}（请求 api.ipify.org / ifconfig.me 超时）"
    echo "常见原因："
    echo "  • 本机防火墙 INPUT/OUTPUT 默认 DROP，连 DNS 都出不去"
    echo "    检查：${CYN}iptables -L INPUT -n | head -3${RST}"
    echo "  • DNS 不可用：${CYN}cat /etc/resolv.conf; ping -c1 1.1.1.1${RST}"
    echo
    echo "也可以直接指定：${CYN}ATT_IP=你的公网IP bash install.sh --server-a${RST}"
    die "已停止"
  fi
  info "本机公网 IP: $aip（B 端将直连此 IP，A 的 IP 不要变）"
  [ "$uport" = 443 ] || warn "使用非默认入口端口: $uport"

  if ss -ltn 2>/dev/null | grep -q ":$uport "; then
    echo
    warn "$uport 已被占用："
    ss -ltnp 2>/dev/null | grep ":$uport " | sed 's/^/    /'

    if [ -n "${ATT_PORT:-}" ]; then
      # 用户显式指定了端口，不自作主张换
      echo
      echo "你显式指定了 ATT_PORT=$uport，但它被占用了。"
      echo "换个端口重跑，或去掉 ATT_PORT 让脚本自动选。"
      die "已停止，没有动你现有服务"
    fi

    # 降级顺序：443 -> 8443 -> 随机高位端口
    local cand=""
    if ! ss -ltn 2>/dev/null | grep -q ':8443 '; then
      cand=8443
      info "8443 空闲，改用 8443"
    else
      warn "8443 也被占用，改用随机高位端口"
      cand=$(free_port)
    fi

    uport="$cand"
    echo
    ok "自动改用端口 $uport，继续部署（没有动你占用 443 的服务）"
    warn "非 443 的 REALITY 伪装效果会打折；如能腾出 443，停掉占用服务后重跑更好"
    warn "云厂商安全组记得放行 $uport/tcp"
    echo
  fi

  local sni
  if [ -n "${ATT_SNI:-}" ]; then
    info "使用指定的 REALITY 回落域名: $ATT_SNI"
    sni=$(pick_sni) || die "指定的回落域名不可用"
  else
    pick_sni_interactive || die "候选回落域名均不可用，请检查网络"
    sni="$SNI_PICKED"
  fi
  # 写进 config.json 前兜底：只允许纯域名，杜绝换行/空格把 JSON 弄坏
  [[ "$sni" =~ ^[A-Za-z0-9.-]+$ ]] || die "回落域名异常: '$sni'"
  ok "回落域名: $sni"

  local rport; rport=$(free_port)
  local uuid buuid sid path priv pub dec enc
  uuid=$("$XRAY_BIN" uuid)
  buuid=$("$XRAY_BIN" uuid)
  sid=$(openssl rand -hex 8)
  path="/$(openssl rand -hex 12)"
  local kp; kp=$("$XRAY_BIN" x25519)
  priv=$(echo "$kp" | awk '/PrivateKey/{print $2}')
  pub=$(echo "$kp"  | awk '/Password/{print $3}')
  local ve; ve=$("$XRAY_BIN" vlessenc 2>/dev/null)
  dec=$(echo "$ve" | grep -o '"decryption": "[^"]*"' | sed -n 1p | cut -d'"' -f4)
  enc=$(echo "$ve" | grep -o '"encryption": "[^"]*"' | sed -n 1p | cut -d'"' -f4)
  [ -n "$dec" ] && [ -n "$enc" ] || die "VLESS Encryption 生成失败（Xray 版本过旧？）"

  # 新/旧 reverse 语法差异：
  #   new: portal 声明在 reverse-in 的 user 上，无顶层 reverse / 无 tunnel.internal 路由
  #   old: 顶层 reverse.portals + 虚拟域名路由
  # XTLS Vision：消除 TLS-in-TLS 指纹，抗封关键。仅 raw 可用，xhttp 不支持 flow。
  # 坑：flow 必须两端完全一致。服务端有 Vision 而客户端没填 flow 时，
  # Xray 直接拒绝（日志：rejected since the client flow is empty），
  # 客户端表现为 EOF / 502。很多客户端导入链接时会丢掉 flow 参数。
  # 客户端导入分享链接后必须保留 flow 字段。
  local a_clients a_users
  if [ "$ATT_TRANSPORT" = xhttp ]; then
    a_clients="{ \"id\": \"$uuid\", \"email\": \"node1\" }"
  else
    a_clients="{ \"id\": \"$uuid\", \"email\": \"node1\", \"flow\": \"xtls-rprx-vision\" }"
  fi
  a_users='"node1"'

  local a_net
  if [ "$ATT_TRANSPORT" = xhttp ]; then
    a_net="\"network\": \"xhttp\",
        \"xhttpSettings\": { \"path\": \"$path\", \"mode\": \"auto\" },"
  else
    a_net="\"network\": \"raw\","
  fi

  local a_reverse_blk a_bclient a_extra_rule
  # 1:1：首个节点 node1 的专属 portal 标签叫 portal-node1；
  # 后续每加一个节点就多一个 bridge client + 一个 portal-<name>。
  if [ "$REVERSE_STYLE" = new ]; then
    a_reverse_blk=""
    a_bclient="{ \"id\": \"$buuid\", \"reverse\": { \"tag\": \"portal-node1\" } }"
    a_extra_rule=""
  else
    a_reverse_blk="  \"reverse\": { \"portals\": [ { \"tag\": \"portal-node1\", \"domain\": \"$TUNNEL_DOMAIN\" } ] },"
    a_bclient="{ \"id\": \"$buuid\" }"
    a_extra_rule="      { \"type\": \"field\", \"inboundTag\": [ \"reverse-in\" ], \"domain\": [ \"full:$TUNNEL_DOMAIN\" ], \"outboundTag\": \"portal-node1\" },"
  fi

  local tmp; tmp=$(mktemp --suffix=.json)
  cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
$a_reverse_blk
  "inbounds": [
    {
      "tag": "user-in",
      "listen": "0.0.0.0",
      "port": $uport,
      "protocol": "vless",
      "settings": {
        "clients": [ $a_clients ],
        "decryption": "none"
      },
      "streamSettings": {
        $a_net
        "security": "reality",
        "realitySettings": {
          "target": "$sni:443",
          "serverNames": [ "$sni" ],
          "privateKey": "$priv",
          "shortIds": [ "$sid" ]
        }
      }
    },
    {
      "tag": "reverse-in",
      "listen": "0.0.0.0",
      "port": $rport,
      "protocol": "vless",
      "settings": {
        "clients": [ $a_bclient ],
        "decryption": "$dec"
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": { "tcpKeepAliveInterval": 10, "tcpKeepAliveIdle": 30, "tcpUserTimeout": 20000 }
      }
    }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" } ],
  "routing": {
    "rules": [
$a_extra_rule
      { "type": "field", "user": [ $a_users ], "outboundTag": "portal-node1" }
    ]
  }
}
EOF

  # 流量统计 + 出口探测（API / probe-in 只听 127.0.0.1，不对外）
  STATS_API_PORT=$(free_port)
  PROBE_PORT=$(free_port)
  while [ "$PROBE_PORT" = "$STATS_API_PORT" ]; do PROBE_PORT=$(free_port); done
  stats_sync "$tmp" 1 || { rm -f "$tmp"; die "统计配置生成失败"; }

  apply_cfg "$tmp"
  harden_service
  tune_tcp
  open_fw "$uport"
  open_fw "$rport"

  mkdir -p "$STATE"
  cat > "$STATE/a.env" <<EOF
ROLE=A
A_IP=$aip
USER_PORT=$uport
REVERSE_PORT=$rport
SNI=$sni
SHORT_ID=$sid
XPATH=$path
TRANSPORT=$ATT_TRANSPORT
REALITY_PUB=$pub
BRIDGE_UUID=$buuid
VLESS_ENC=$enc
REVERSE_STYLE=$REVERSE_STYLE
STATS_API_PORT=$STATS_API_PORT
PROBE_PORT=$PROBE_PORT
EOF
  chmod 600 "$STATE/a.env"

  local token
  token=$(printf '%s|%s|%s|%s|%s' "$aip" "$rport" "$buuid" "$enc" "$REVERSE_STYLE" | base64 -w0)

  echo
  echo "${BLD}=========== 服务器 A 部署完成 ===========${RST}"
  echo
  # 从外部视角验证反代端口真的通，否则 B 端会白跑一轮
  echo
  info "验证反代端口 $rport 是否从外网可达 ..."
  local probe_ok=0 body
  body=$(curl -fsS --max-time 20 "https://ports.yougetsignal.com/check-port.php" \
         --data "remoteAddress=$aip&portNumber=$rport" 2>/dev/null || true)
  if echo "$body" | grep -qi 'open'; then
    probe_ok=1
  fi
  if [ "$probe_ok" = 1 ]; then
    ok "外网可达 $aip:$rport"
  else
    echo
    echo "${YEL}${BLD}⚠ 外网似乎连不上 $aip:$rport${RST}"
    echo "这样 B 端隧道建不起来。本机防火墙已处理，请检查："
    echo "  • ${BLD}云厂商安全组${RST}是否放行 ${BLD}$rport/tcp${RST}（最常见原因）"
    echo "  • 上游服务商是否限制端口"
    echo "放行后隧道会自动建立，不用重跑本脚本。"
    echo "（探测服务可能不准，若你确定已放行可忽略）"
  fi

  echo
  echo "${BLD}下一步：到服务器 B（AT&T 出口机）上执行：${RST}"
  echo
  echo "${GRN}bash <(curl -fsSL $RAW_URL) --bridge $token${RST}"
  echo
  echo "${YEL}这串 token 含隧道密钥，只在你自己两台机器间使用，不要外发。${RST}"
  echo
  show_links
}

# ================= 服务器 B：反向出口 =================
deploy_b(){
  need_root
  local token="${1:-}"
  [ -n "$token" ] || die "缺少 token，请用 A 端输出的完整命令"

  local dec aip rport buuid enc tstyle
  dec=$(echo "$token" | base64 -d 2>/dev/null) || die "token 解析失败"
  IFS='|' read -r aip rport buuid enc tstyle <<<"$dec"
  [ -n "$aip" ] && [ -n "$rport" ] && [ -n "$buuid" ] && [ -n "$enc" ] || die "token 内容不完整"

  install_deps; install_xray

  # A/B 两端都强制同一个 $XRAY_VER，语法必然一致。若 token 带的 style 不一致，
  # 说明 A 端是用旧版本部署的，必须让 A 也重跑一次，否则握手会失败
  # （客户端报 unknown version: 72）。
  if [ -n "${tstyle:-}" ] && [ "$tstyle" != "$REVERSE_STYLE" ]; then
    warn "A 端 reverse 语法是 $tstyle，本机是 $REVERSE_STYLE —— 两端 Xray 版本不一致"
    die "请在 A 端用同一版脚本重跑菜单 1，拿到新 token 再回来"
  fi

  info "将主动拨向 A: $aip:$rport（reverse 语法 $REVERSE_STYLE）"

  if ! timeout 8 bash -c "</dev/tcp/$aip/$rport" 2>/dev/null; then
    warn "暂时连不上 $aip:$rport —— 检查 A 的防火墙/安全组是否放行了该端口"
    warn "仍会继续部署；隧道会在通了之后自动建立"
  else
    ok "A 的反代端口可达"
  fi

  # 新语法：bridge 声明在 outbound 的 reverse 字段（必须用 simplified style，不能用 vnext）
  # 关键：新版 freedom 对 vless-reverse 入站默认 block 全部（防滥用），
  # 必须显式 finalRules 放行，否则隧道通但流量全被 blackhole
  local tmp; tmp=$(mktemp --suffix=.json)
  if [ "$REVERSE_STYLE" = new ]; then
    cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "tunnel",
      "protocol": "vless",
      "settings": {
        "address": "$aip",
        "port": $rport,
        "id": "$buuid",
        "encryption": "$enc",
        "reverse": { "tag": "bridge" }
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": { "tcpKeepAliveInterval": 10, "tcpKeepAliveIdle": 30, "tcpUserTimeout": 20000 }
      }
    },
    {
      "tag": "freedom",
      "protocol": "freedom",
      "settings": {
        "finalRules": [
          { "action": "block", "ip": [ "geoip:private" ] },
          { "action": "allow" }
        ]
      },
      "streamSettings": { "sockopt": { "domainStrategy": "UseIPv4" } }
    }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "bridge" ], "outboundTag": "freedom" }
    ]
  }
}
EOF
  else
    cat > "$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "reverse": { "bridges": [ { "tag": "bridge", "domain": "$TUNNEL_DOMAIN" } ] },
  "inbounds": [],
  "outbounds": [
    {
      "tag": "tunnel",
      "protocol": "vless",
      "settings": {
        "vnext": [ {
          "address": "$aip",
          "port": $rport,
          "users": [ { "id": "$buuid", "encryption": "$enc" } ]
        } ]
      },
      "streamSettings": {
        "network": "raw",
        "sockopt": { "tcpKeepAliveInterval": 10, "tcpKeepAliveIdle": 30, "tcpUserTimeout": 20000 }
      }
    },
    { "tag": "freedom", "protocol": "freedom" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": [ "bridge" ], "domain": [ "full:$TUNNEL_DOMAIN" ], "outboundTag": "tunnel" },
      { "type": "field", "inboundTag": [ "bridge" ], "outboundTag": "freedom" }
    ]
  }
}
EOF
  fi

  apply_cfg "$tmp"
  harden_service
  tune_tcp

  mkdir -p "$STATE"
  printf 'ROLE=B\nA_IP=%s\nREVERSE_PORT=%s\n' "$aip" "$rport" > "$STATE/b.env"
  chmod 600 "$STATE/b.env"

  echo
  info "等待反向隧道建立 ..."
  local i estab=0
  for i in $(seq 1 15); do
    if ss -tn state established 2>/dev/null | grep -q "$aip:$rport"; then estab=1; break; fi
    sleep 2
  done

  echo
  echo "${BLD}=========== 服务器 B 部署完成 ===========${RST}"
  if [ "$estab" = 1 ]; then
    ok "反向隧道已建立（B → A ESTAB）"
  else
    echo "${YEL}${BLD}⚠ 隧道未建立${RST}"
    echo "B 已部署完成并会持续重试，卡在这里只有一个原因："
    echo "  ${BLD}A 机的 $rport/tcp 没有对外开放${RST}"
    echo
    echo "去 A 机的${BLD}云厂商控制台安全组${RST}放行 ${BLD}$rport/tcp${RST}（入方向）。"
    echo "放行后无需重跑任何命令，30 秒内隧道会自动建立。"
    echo
    echo "确认方法（本机）：${CYN}ss -tn state established | grep $rport${RST}"
    echo "或直接测连通：  ${CYN}timeout 5 bash -c '</dev/tcp/$aip/$rport' && echo 通 || echo 不通${RST}"
  fi
  echo
  ok "B 端无任何入站监听，公网扫不到"
  ok "B 换 IP 无需任何操作，Xray 会自动重拨"
  echo
  warn "如需把 SSH 迁到高位端口（降低暴露面），单独跑：菜单 10"
}

# ================= 节点 / 出口机 管理 =================
# 架构：一个节点 = 一台出口机 = 一个 portal 标签（严格 1:1）
#   A 端 reverse-in 挂多个 bridge client，每个带自己的 reverse.tag
#   路由一节点一条规则：user:[nodeX] -> portal-nodeX
# B 端无需任何改动：它只认 token 里的 uuid，一台 B 一个 uuid 天然分开，
# 多台 B 复用同一个反代端口没问题。

# 输出：节点名 <TAB> portal标签 <TAB> 出口uuid（一行一个节点）
# portal 标签或 uuid 为空 = 该节点没有绑定出口机
list_exits(){
  [ -f "$CFG" ] || return 1
  ATT_CFG="$CFG" python3 - <<'PY'
import json,os,sys
try:
    d=json.load(open(os.environ['ATT_CFG']))
except Exception:
    sys.exit(1)
bridges={}
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            t=(c.get('reverse') or {}).get('tag')
            if t:
                bridges[t]=c.get('id','')
node2portal={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # probe-in 的探测规则（user=probe-<节点>）不是节点规则
    if ot.startswith('portal') and 'probe-in' not in (r.get('inboundTag') or []):
        for u in r.get('user',[]):
            node2portal[u]=ot
for ib in d.get('inbounds',[]):
    # user-in = 主入口；user-in-<端口> = 加节点时指定了别的端口/伪装域名生成的独立入口
    if ib.get('tag')=='user-in' or str(ib.get('tag','')).startswith('user-in-'):
        for c in ib.get('settings',{}).get('clients',[]):
            n=c.get('email','node')
            p=node2portal.get(n,'')
            print('%s\t%s\t%s'%(n,p,bridges.get(p,'')))
PY
}

# 只列节点名
list_nodes(){ list_exits | cut -f1; }

# xray -test 查不出来的错配，必须自己拦。以下三种实测（Xray 26.6.27）
# 全部返回 Configuration OK，Xray 一个都不管：
#   1) 节点没有 portal 规则 -> 流量 fallthrough 到 direct，从 A 出网，泄露 A 的 IP
#   2) portal 标签重复     -> Xray 在多条隧道间随机派流，出口 IP 不确定
#   3) 规则指向不存在的标签 -> 静默失效
validate_cfg(){
  local f="${1:-$CFG}"
  ATT_CFG="$f" python3 - <<'PY'
import json,os,sys
err=[]
try:
    d=json.load(open(os.environ['ATT_CFG']))
except Exception as e:
    print('配置不是合法 JSON: %s'%e); sys.exit(1)

bridge_tags=[]
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            t=(c.get('reverse') or {}).get('tag')
            if t:
                bridge_tags.append(t)
dup=sorted({t for t in bridge_tags if bridge_tags.count(t)>1})
for t in dup:
    err.append('portal 标签重复: %s（流量会在多条隧道间随机派发）'%t)

nodes=[]
ports={}
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='user-in' or str(ib.get('tag','')).startswith('user-in-'):
        p=ib.get('port')
        if p in ports:
            err.append('入口端口 %s 被 %s 和 %s 重复使用'%(p,ports[p],ib.get('tag')))
        ports[p]=ib.get('tag')
        for c in ib.get('settings',{}).get('clients',[]):
            nodes.append(c.get('email','node'))
for n in sorted({n for n in nodes if nodes.count(n)>1}):
    err.append('节点名重复: %s'%n)

node2portal={}
probe2portal={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # 按 inboundTag 区分：probe-in 的是出口探测规则（user=probe-<节点>），单独校验
    if 'probe-in' in (r.get('inboundTag') or []):
        if ot.startswith('portal') and ot not in bridge_tags:
            err.append('探测路由指向不存在的 portal 标签: %s'%ot)
        for u in r.get('user',[]):
            probe2portal[u]=ot
        continue
    if not ot.startswith('portal'):
        continue
    if ot not in bridge_tags:
        err.append('路由指向不存在的 portal 标签: %s'%ot)
    for u in r.get('user',[]):
        if u not in nodes:
            err.append('路由里有悬空用户: %s（入站里没这个节点）'%u)
        node2portal[u]=ot

for n in nodes:
    if n not in node2portal:
        err.append('节点 %s 没绑定出口机（流量会从 A 直接出网，泄露 A 的 IP）'%n)

# 启用了出口探测时：探测账号必须和节点一一对应，且探测走的出口必须等于节点的出口
if any(ib.get('tag')=='probe-in' for ib in d.get('inbounds',[])):
    for u,ot in probe2portal.items():
        n=u[len('probe-'):] if u.startswith('probe-') else None
        if n not in nodes:
            err.append('探测路由里有悬空账号: %s'%u)
        elif node2portal.get(n) and ot!=node2portal[n]:
            err.append('节点 %s 的探测出口(%s)和节点出口(%s)不一致'%(n,ot,node2portal[n]))

if err:
    for e in err:
        print(e)
    sys.exit(1)
PY
}

# 旧版（1.x）只有一个叫 "portal" 的标签，所有节点共享它。
# 升级做法：标签 portal -> portal-<首个节点名>，bridge uuid 不变，
# 所以 B 端不用重新部署，老 token 和客户端链接全部继续有效。
needs_migrate(){
  [ -f "$CFG" ] || return 1
  grep -q '"tag": "portal"' "$CFG" 2>/dev/null
}

migrate_cfg(){
  need_root
  [ -f "$STATE/a.env" ] || die "只有 A 端需要升级配置"
  needs_migrate || { ok "配置已是多出口结构，无需升级"; return 0; }

  info "检测到旧的单 portal 配置，升级为多出口结构 ..."
  local tmp; tmp=$(mktemp --suffix=.json)
  local rc=0
  ATT_CFG="$CFG" python3 - > "$tmp" <<'PY' || rc=$?
import json,os,sys
d=json.load(open(os.environ['ATT_CFG']))
first=None
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='user-in':
        cs=ib.get('settings',{}).get('clients',[])
        if cs:
            first=cs[0].get('email','node1')
        break
if not first:
    raise SystemExit('NONODE')
new='portal-%s'%first
hit=False
for ib in d.get('inbounds',[]):
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            rv=c.get('reverse') or {}
            if rv.get('tag')=='portal':
                rv['tag']=new; c['reverse']=rv; hit=True
for r in d.get('routing',{}).get('rules',[]):
    if r.get('outboundTag')=='portal':
        r['outboundTag']=new; hit=True
if not hit:
    raise SystemExit('NOTHING')
sys.stderr.write(new+'\n')
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"; die "升级失败：配置解析异常（原配置未改动）"
  fi
  # 已启用统计时同步 email / 探测账号 / 探测路由（未启用则原样）
  stats_sync "$tmp" 0 || { rm -f "$tmp"; die "统计/探测结构同步失败（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"
    echo "$vmsg" | sed 's/^/    /'
    die "升级后配置自检不通过（原配置未改动）"
  fi
  apply_cfg "$tmp"
  ok "配置已升级为多出口结构"
  ok "B 端无需重新部署，客户端链接也不变（bridge uuid 未变）"
  local shared; shared=$(list_exits | awk -F'\t' '{print $2}' | sort | uniq -d)
  if [ -n "$shared" ]; then
    echo
    warn "以下出口被多个节点共用（遗留的旧结构，不是 1:1）："
    local p
    while read -r p; do
      [ -z "$p" ] && continue
      echo "    $p <- $(list_exits | awk -F'\t' -v t="$p" '$2==t{printf "%s ", $1}')"
    done <<< "$shared"
    warn "这些节点出口 IP 相同。想让它们各走自己的出口机："
    warn "  先删掉多余的（菜单 7），再用菜单 5 每个重新加一台出口机"
  fi
}

# A 端所有改动入口先跑一下，避免在旧结构上叠新出口
ensure_migrated(){
  needs_migrate || return 0
  warn "当前是旧的单出口配置，先自动升级"
  migrate_cfg
}

# 菜单入口：交互式平滑升级。比 --migrate 多一层说明和确认，
# 且不会因为「本机不是 A 端 / 无需升级」就退出整个脚本。
migrate_menu(){
  if [ ! -f "$STATE/a.env" ]; then
    warn "本机不是 A 端（入口机），不需要升级配置"
    [ -f "$STATE/b.env" ] && info "B 端（出口机）无需任何改动，老 token 继续有效"
    return 1
  fi
  if ! needs_migrate; then
    ok "配置已经是 1:1 多出口结构，无需升级"
    echo
    show_exits || true
    return 0
  fi

  echo "${BLD}--- 平滑升级为 1:1 多出口结构 ---${RST}"
  echo
  echo "当前配置是旧的单出口结构：所有节点共用一个 ${CYN}portal${RST} 标签，"
  echo "也就是不管几个节点，出口永远是同一台出口机。"
  echo
  echo "升级会把标签改名为 ${CYN}portal-<首个节点名>${RST}，并让后续新增节点"
  echo "各自绑定专属出口机。${BLD}bridge uuid 保持不变${RST}，所以："
  echo "  ${GRN}•${RST} 出口机（B）不用重新部署，老 token 继续有效"
  echo "  ${GRN}•${RST} 客户端分享链接不变，不用重新导入"
  echo "  ${GRN}•${RST} 原配置自动备份到 $CFG.bak-*，服务起不来自动回滚"
  echo
  local n; n=$(list_nodes 2>/dev/null | grep -c . 2>/dev/null) || n=0
  [ -n "$n" ] || n=0
  if [ "$n" -gt 1 ] 2>/dev/null; then
    warn "你现在有 $n 个节点共用一台出口机。升级${BLD}不会${RST}凭空造出新出口机，"
    warn "它们升级后仍然共享。想让它们各走自己的出口机，升级完后："
    warn "  先用菜单 7 删掉多余节点，再用菜单 5 每个重新加一台出口机"
    echo
  fi
  warn "升级会重启 att-tunnel 服务，期间连接会断几秒"
  read -rp "确认升级？（输 yes）: " c
  [ "$c" = yes ] || { warn "已取消，配置未改动"; return; }
  echo
  migrate_cfg
}

# show_links [NAME]：不带参数列出全部；带 NAME 只输出该节点的一行 vless 链接
show_links(){
  local only="${1:-}" found=0
  [ -f "$STATE/a.env" ] || { warn "本机不是 A 端，或尚未部署"; return 1; }
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  [ -n "$only" ] || echo "${BLD}--- 客户端分享链接 ---${RST}"
  local epath; epath=$(printf '%s' "$XPATH" | sed 's|/|%2F|g')
  local tr="${TRANSPORT:-xhttp}"
  local uport="${USER_PORT:-443}"
  local rows; rows=$(list_exits 2>/dev/null || true)
  local n uuid fl qs np ns
  # flow 由每个用户自己的配置决定，不能一刀切；端口 / 伪装域名按节点所在入站（user-in 或 user-in-<端口>）
  while read -r n uuid fl np ns; do
    [ -z "$n" ] && continue
    [ "$fl" = "-" ] && fl=""
    [ -n "${only:-}" ] && [ "$n" != "$only" ] && continue
    if [ "$tr" = xhttp ]; then
      qs="type=xhttp&path=$epath&mode=auto"
    elif [ "$fl" = "xtls-rprx-vision" ]; then
      qs="type=tcp&flow=xtls-rprx-vision"
    else
      qs="type=tcp"
    fi
    # 每个节点标注它的专属出口（1:1）
    local ptag tip=""
    ptag=$(printf '%s\n' "$rows" | awk -F'\t' -v k="$n" '$1==k{print $2}')
    if [ -z "$ptag" ]; then
      tip="  ${RED}未绑定出口机（流量会从 A 出网，泄露 A 的 IP）${RST}"
    else
      tip="  出口：${CYN}$ptag${RST}"
    fi
    local link="vless://$uuid@$A_IP:${np:-$uport}?encryption=none&security=reality&$qs&sni=${ns:-$SNI}&fp=chrome&pbk=$REALITY_PUB&sid=$SHORT_ID#$n"
    # --link NAME：只输出这一条链接（给面板用）
    if [ -n "${only:-}" ]; then echo "$link"; found=1; continue; fi
    echo
    echo "${CYN}[$n]${RST}$tip"
    echo "$link"
  done < <("$XRAY_BIN" -test -config "$CFG" >/dev/null 2>&1 && ATT_CFG="$CFG" python3 - <<'PY'
import json,os
d=json.load(open(os.environ['ATT_CFG']))
for ib in d['inbounds']:
    t=str(ib.get('tag',''))
    if t=='user-in' or t.startswith('user-in-'):
        rs=(ib.get('streamSettings') or {}).get('realitySettings') or {}
        sni=(rs.get('serverNames') or [''])[0]
        for c in ib['settings']['clients']:
            print(c.get('email','node'), c['id'], c.get('flow','') or '-', ib.get('port',''), sni)
PY
)
  if [ -n "${only:-}" ]; then
    [ "${found:-0}" = 1 ] || die "节点 $only 不存在"
    return 0
  fi
  echo
  echo "${BLD}一个节点 = 一台出口机${RST}（严格 1:1）。拿某节点的出口机部署命令：菜单 6"
  echo "隧道是否全部连上：菜单 8（自检）。A 侧无法把单条连接对到具体节点，只能看总数。"
  if [ "$tr" != xhttp ]; then
    echo "${BLD}客户端必须带上 ${GRN}flow=xtls-rprx-vision${RST}${BLD}（导入后请核对）${RST}"
    echo "若报 EOF / 502，几乎肯定是客户端丢了 flow 参数。"
  fi
}

# 打印某台出口机的部署命令（token 含隧道密钥）
print_b_cmd(){
  local buuid="$1" name="${2:-}"
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  local token
  token=$(printf '%s|%s|%s|%s|%s' "$A_IP" "$REVERSE_PORT" "$buuid" "${VLESS_ENC:-none}" "${REVERSE_STYLE:-new}" | base64 -w0)
  echo
  echo "${BLD}到这个节点的出口机${name:+（$name）}上执行：${RST}"
  echo
  echo "${GRN}bash <(curl -fsSL $RAW_URL) --bridge $token${RST}"
  echo
  echo "${YEL}这串 token 含隧道密钥，只在你自己两台机器间使用，不要外发。${RST}"
}

add_node(){
  need_root
  [ -f "$STATE/a.env" ] || die "只能在 A 端加节点"
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  ensure_migrated
  cfg_lock
  local name="${1:-}"
  if [ -z "$name" ] && ! noninteractive; then read -rp "节点名称（如 node2）: " name; fi
  [ -n "$name" ] || die "名称不能为空"
  # 节点名会拼进 portal 标签和分享链接，限制字符集（网页面板用同一条规则）
  printf '%s' "$name" | grep -qE '^[A-Za-z0-9_-]{1,32}$' \
    || die "名称只能用字母/数字/下划线/连字符，最多 32 位"
  list_nodes 2>/dev/null | grep -qxF "$name" && die "节点 $name 已存在（原配置未改动）"

  # 入口端口：ATT_NODE_PORT > 交互输入 > 主入口端口
  local uport="${ATT_NODE_PORT:-}"
  if [ -z "$uport" ] && ! noninteractive; then
    read -rp "为这个节点指定入口端口（回车使用已有的 ${USER_PORT:-443}）: " uport
  fi
  [ -n "$uport" ] || uport="${USER_PORT:-443}"
  case "$uport" in (*[!0-9]*) die "端口必须是数字";; esac
  [ "$uport" -ge 1 ] && [ "$uport" -le 65535 ] || die "端口越界（1-65535）"
  uport=$((10#$uport))

  # 伪装域名：只有单独端口的新入口才能自定义；共用已有入口时沿用它的域名
  local nsni="${ATT_NODE_SNI:-}" existing=""
  existing=$(ATT_CFG="$CFG" P="$uport" python3 -c '
import json,os
d=json.load(open(os.environ["ATT_CFG"]))
for ib in d.get("inbounds",[]):
    t=str(ib.get("tag",""))
    if (t=="user-in" or t.startswith("user-in-")) and str(ib.get("port"))==os.environ["P"]:
        rs=(ib.get("streamSettings") or {}).get("realitySettings") or {}
        print((rs.get("serverNames") or ["?"])[0]); break')
  if [ -n "$existing" ]; then
    if [ -n "$nsni" ] && [ "$nsni" != "$existing" ]; then
      warn "端口 $uport 已有入口，伪装域名沿用它的 $existing（忽略 $nsni）"
    fi
    nsni="$existing"
  else
    [ "$uport" = "${REVERSE_PORT:-}" ] && die "端口 $uport 是反代隧道端口，不能当入口"
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$uport\$"; then
      die "端口 $uport 已被占用（原配置未改动）"
    fi
    if [ -z "$nsni" ] && ! noninteractive; then
      read -rp "伪装域名（回车沿用主入口的 $SNI；输 list 从预置列表选；或直接输入域名）: " nsni
      if [ "$nsni" = list ]; then pick_sni_interactive || die "没有可用的伪装域名"; nsni="$SNI_PICKED"; fi
    fi
    [ -n "$nsni" ] || nsni="$SNI"
    printf '%s' "$nsni" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' \
      || die "伪装域名格式不对：$nsni"
    if [ "$nsni" != "$SNI" ]; then
      info "实测 $nsni 的 TLS 1.3 ..."
      sni_ok "$nsni" || die "伪装域名 $nsni 不支持 TLS 1.3 或连不上（原配置未改动）"
    fi
    info "节点 $name 将使用单独入口：端口 $uport，伪装域名 $nsni"
  fi

  local uuid buuid
  uuid=$("$XRAY_BIN" uuid)    # 客户端用
  buuid=$("$XRAY_BIN" uuid)   # 这个节点专属出口机用

  local tmp; tmp=$(mktemp --suffix=.json)
  local rc=0
  NEW_NAME="$name" NEW_UUID="$uuid" NEW_BUUID="$buuid" NEW_PORT="$uport" NEW_SNI="$nsni" \
    ATT_CFG="$CFG" python3 - > "$tmp" <<'PY' || rc=$?
import copy,json,os
d=json.load(open(os.environ['ATT_CFG']))
name=os.environ['NEW_NAME']
uuid=os.environ['NEW_UUID']; buuid=os.environ['NEW_BUUID']
port=int(os.environ['NEW_PORT']); sni=os.environ['NEW_SNI']
ptag='portal-%s'%name
def is_ui(ib):
    t=str(ib.get('tag',''))
    return t=='user-in' or t.startswith('user-in-')
uis=[ib for ib in d['inbounds'] if is_ui(ib)]
main=[ib for ib in uis if ib.get('tag')=='user-in']
if not main:
    raise SystemExit('NOMAIN')
main=main[0]
for ib in uis:
    if any(c.get('email')==name for c in ib['settings']['clients']):
        raise SystemExit('DUP')

# raw 模式必带 Vision（抗封）；xhttp 不支持 flow
vision=(main.get('streamSettings') or {}).get('network')=='raw'
c={'id':uuid,'email':name}
if vision:
    c['flow']='xtls-rprx-vision'

# 节点放进同端口的入口；该端口还没有入口时，按主入口克隆一个 user-in-<端口>
# （同一套 REALITY 密钥 / shortId，只换端口和伪装域名）
tgt=[ib for ib in uis if ib.get('port')==port]
if tgt:
    tgt[0]['settings']['clients'].append(c)
else:
    ib=copy.deepcopy(main)
    ib['tag']='user-in-%d'%port
    ib['port']=port
    ib['settings']['clients']=[c]
    rs=(ib.get('streamSettings') or {}).get('realitySettings')
    if rs is not None:
        rs['serverNames']=[sni]
        if 'target' in rs: rs['target']='%s:443'%sni
        if 'dest' in rs: rs['dest']='%s:443'%sni
    d['inbounds'].insert(d['inbounds'].index(uis[-1])+1, ib)

# 严格 1:1：这个节点自己的 bridge client + 自己的 portal 标签
for ib in d['inbounds']:
    if ib.get('tag')=='reverse-in':
        bs=ib['settings']['clients']
        if any((b.get('reverse') or {}).get('tag')==ptag for b in bs):
            raise SystemExit('DUPTAG')
        bs.append({'id':buuid,'reverse':{'tag':ptag}})

# 一节点一条路由，不往旧规则里追加
d.setdefault('routing',{}).setdefault('rules',[]).append(
    {'type':'field','user':[name],'outboundTag':ptag})
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "节点名已存在或配置解析失败（原配置未改动）"
  fi
  # 已启用统计时同步 email / 探测账号 / 探测路由（未启用则原样）
  stats_sync "$tmp" 0 || { rm -f "$tmp"; die "统计/探测结构同步失败（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"; echo "$vmsg" | sed 's/^/    /'
    die "配置自检不通过（原配置未改动）"
  fi

  apply_cfg "$tmp"
  open_fw "$REVERSE_PORT" 2>/dev/null || true
  [ "$uport" = "${USER_PORT:-443}" ] || open_fw "$uport" 2>/dev/null || true
  ok "节点 $name 已添加（专属出口 portal-$name，入口端口 $uport，伪装域名 $nsni）"
  warn "这个节点现在还没有出口机，隧道未建立前不可用"
  print_b_cmd "$buuid" "$name"
  echo
  info "出口机部署完后，跑菜单 8（自检）确认隧道已连"
  show_links
}

# 节点 / 出口机 对应表
show_exits(){
  [ -f "$STATE/a.env" ] || { warn "本机不是 A 端，或尚未部署"; return 1; }
  local rows; rows=$(list_exits) || die "读不到配置 $CFG"
  [ -n "$rows" ] || { warn "配置里没有任何节点"; return 1; }
  echo "${BLD}--- 节点 / 出口机（严格 1:1）---${RST}"
  local i=0 n p u
  while IFS=$'\t' read -r n p u; do
    [ -z "$n" ] && continue
    i=$((i+1))
    if [ -z "$p" ]; then
      echo "  $i) $n  ${RED}未绑定出口机${RST}"
    else
      echo "  $i) $n  →  $p"
    fi
  done <<< "$rows"
  echo
  local shared; shared=$(printf '%s\n' "$rows" | awk -F'\t' '$2!=""{print $2}' | sort | uniq -d)
  if [ -n "$shared" ]; then
    warn "有出口被多个节点共用，这些节点出口 IP 相同（不是 1:1）："
    local p2
    while read -r p2; do
      [ -z "$p2" ] && continue
      echo "    $p2 <- $(printf '%s\n' "$rows" | awk -F'\t' -v t="$p2" '$2==t{printf "%s ", $1}')"
    done <<< "$shared"
  fi
  info "拿某节点的出口机部署命令：菜单 6；隧道连接情况：菜单 8（自检）"
}

# 重新拿某个节点的出口机部署命令（换机、重装时用）
show_exit_cmd(){
  [ -f "$STATE/a.env" ] || die "只能在 A 端查"
  local rows; rows=$(list_exits) || die "读不到配置 $CFG"
  [ -n "$rows" ] || die "配置里没有任何节点"
  local name="${1:-}"
  if [ -z "$name" ]; then
    echo "${BLD}--- 节点 / 出口机 ---${RST}"
    local i=0 n p u
    while IFS=$'\t' read -r n p u; do
      [ -z "$n" ] && continue
      i=$((i+1))
      echo "  $i) $n  ${p:-${RED}未绑定${RST}}"
    done <<< "$rows"
    echo
    read -rp "查哪个节点的出口机命令？（名称或序号，回车取消）: " name
    [ -n "$name" ] || { warn "已取消"; return; }
  fi
  if printf '%s' "$name" | grep -qE '^[0-9]+$'; then
    name=$(printf '%s\n' "$rows" | sed -n "${name}p" | cut -f1)
    [ -n "$name" ] || die "序号超出范围"
  fi
  local line; line=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1==n')
  [ -n "$line" ] || die "节点 $name 不存在"
  local buuid; buuid=$(printf '%s' "$line" | cut -f3)
  [ -n "$buuid" ] || die "节点 $name 没有绑定出口机（配置异常，跑菜单 8 自检）"
  print_b_cmd "$buuid" "$name"
}

del_node(){
  need_root
  [ -f "$STATE/a.env" ] || die "只能在 A 端删节点"
  ensure_migrated
  local rows; rows=$(list_exits) || die "读不到配置 $CFG"
  [ -n "$rows" ] || die "配置里没有任何节点"
  local names; names=$(printf '%s\n' "$rows" | cut -f1)
  local total; total=$(printf '%s\n' "$names" | grep -c .)

  cfg_lock
  local name="${1:-}"
  if [ -z "$name" ]; then
    noninteractive && die "非交互模式必须指定节点名：--del NAME"
    echo "${BLD}--- 当前节点 / 出口机 ---${RST}"
    local i=0 n p u
    while IFS=$'\t' read -r n p u; do
      [ -z "$n" ] && continue
      i=$((i+1))
      echo "  $i) $n  ${p:-${RED}未绑定${RST}}"
    done <<< "$rows"
    echo
    read -rp "删除哪个节点？（输名称或序号，回车取消）: " name
    [ -n "$name" ] || { warn "已取消"; return; }
  fi

  # 允许按序号选
  if printf '%s' "$name" | grep -qE '^[0-9]+$'; then
    local picked; picked=$(printf '%s\n' "$names" | sed -n "${name}p")
    [ -n "$picked" ] || die "序号 $name 超出范围（共 $total 个）"
    name="$picked"
  fi

  printf '%s\n' "$names" | grep -qxF "$name" || die "节点 $name 不存在"
  # 入站至少要留一个 client，否则 Xray 校验不过；真要清空请走卸载
  [ "$total" -gt 1 ] || die "这是最后一个节点，删掉入口就没人能用了。要停用请用菜单 11（卸载）"

  local ptag; ptag=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$name" '$1==n{print $2}')
  echo
  warn "将一并删除它的专属出口绑定${ptag:+（$ptag）}"
  warn "对应的出口机会失去连接。它上面的 att-tunnel 需你自己去卸载（否则它会一直重试拨号）"
  local c=""
  if noninteractive; then
    # 非交互（网页面板 / 脚本调用）：必须显式 ATT_YES=1，面板那边已让用户输入节点名确认
    [ "${ATT_YES:-}" = 1 ] || die "非交互删除需要 ATT_YES=1"
    c=yes
  else
    read -rp "确认删除节点 ${BLD}$name${RST}？它的分享链接会立刻失效（输 yes）: " c
  fi
  [ "$c" = yes ] || { warn "已取消"; return; }

  local tmp; tmp=$(mktemp --suffix=.json)
  local rc=0
  DEL_NAME="$name" ATT_CFG="$CFG" python3 - > "$tmp" <<'PY' || rc=$?
import json,os
d=json.load(open(os.environ['ATT_CFG']))
name=os.environ['DEL_NAME']

# 这个节点绑的 portal 标签（从路由反查，比拼名字可靠）
ptags=set()
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    if ot.startswith('portal') and name in r.get('user',[]) and 'probe-in' not in (r.get('inboundTag') or []):
        ptags.add(ot)

found=False
ibs=[]
for ib in d.get('inbounds',[]):
    t=str(ib.get('tag',''))
    if t=='user-in' or t.startswith('user-in-'):
        cs=ib['settings']['clients']
        keep=[c for c in cs if c.get('email')!=name]
        if len(keep)!=len(cs):
            found=True
        if not keep:
            # 额外入口（user-in-<端口>）空了就整个删掉；主入口必须留至少一个
            if t!='user-in':
                continue
            raise SystemExit('LAST')
        ib['settings']['clients']=keep
    ibs.append(ib)
d['inbounds']=ibs
if not found:
    raise SystemExit('NOTFOUND')

# 1:1：摘掉它专属的 bridge client。仅当没有其他节点共用该标签时才删，
# 防止旧结构（多节点共一个 portal）下误删别人的隧道。
still={}
for r in d.get('routing',{}).get('rules',[]):
    ot=r.get('outboundTag','')
    # 探测规则（probe-in）不算“共用”，否则 probe-<节点> 会让 bridge 永远删不掉
    if ot.startswith('portal') and 'probe-in' not in (r.get('inboundTag') or []):
        others=[u for u in r.get('user',[]) if u!=name]
        if others:
            still[ot]=others
drop={t for t in ptags if t not in still}
if drop:
    for ib in d.get('inbounds',[]):
        if ib.get('tag')=='reverse-in':
            ib['settings']['clients']=[
                b for b in ib['settings']['clients']
                if (b.get('reverse') or {}).get('tag') not in drop]

# 同步摘掉 portal 路由里的这个用户，用空了的规则整条删掉
rules=[]
for r in d.get('routing',{}).get('rules',[]):
    if 'user' in r:
        r['user']=[u for u in r['user'] if u!=name]
        if not r['user']:
            continue
    rules.append(r)
d['routing']['rules']=rules
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    die "删除失败：配置解析异常或节点已不存在（原配置未改动）"
  fi
  # 已启用统计时同步 email / 探测账号 / 探测路由（未启用则原样）
  stats_sync "$tmp" 0 || { rm -f "$tmp"; die "统计/探测结构同步失败（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"; echo "$vmsg" | sed 's/^/    /'
    die "配置自检不通过（原配置未改动）"
  fi

  # apply_cfg 会先 xray -test 校验，失败自动回滚
  apply_cfg "$tmp"
  ok "节点 $name 及其出口绑定已删除（已备份原配置到 $CFG.bak-*）"
  echo
  info "剩下的节点："
  show_links
}

# ================= 流量统计 / 出口探测（A 端） =================
# 设计：
#   stats + api（只听 127.0.0.1:<随机口>）+ policy 打开按用户计流量。
#   用户 client 的 email = 节点名 → 计数器 user>>>节点>>>traffic>>>uplink/downlink
#   bridge client 的 email = exit.portal-<节点>（出口侧计数，方向相反，面板不用）
#   probe-in：127.0.0.1 上的 socks（密码认证），每个节点一个账号 probe-<节点>，
#   路由 user:[probe-<节点>] + inboundTag:[probe-in] -> portal-<节点>，
#   面板经它访问 api.ipify.org，拿到的就是该节点出口机（B）的实时公网 IP。
#   statsonlineiplist 对反向 bridge 拿不到 IP（已实测），所以只能这样探。
#   probe-in 兜底规则 -> blackhole：探测账号万一没对上规则，宁可失败也不从 A 直出（否则会显示 A 的 IP）。
# 分享链接、B 端配置都不变。

# 是否已启用统计（config 里有 api 段 + probe-in 入站）
stats_enabled(){
  [ -f "$CFG" ] || return 1
  ATT_CFG="$CFG" python3 - <<'PY'
import json,os,sys
d=json.load(open(os.environ['ATT_CFG']))
ok=bool((d.get('api') or {}).get('listen')) and any(ib.get('tag')=='probe-in' for ib in d.get('inbounds',[]))
sys.exit(0 if ok else 1)
PY
}

# 统计/探测用的两个本地端口，存在 a.env 里（STATS_API_PORT / PROBE_PORT）
ensure_stats_ports(){
  # shellcheck disable=SC1090
  source "$STATE/a.env"
  if [ -z "${STATS_API_PORT:-}" ]; then
    STATS_API_PORT=$(free_port); echo "STATS_API_PORT=$STATS_API_PORT" >> "$STATE/a.env"
  fi
  if [ -z "${PROBE_PORT:-}" ] || [ "$PROBE_PORT" = "$STATS_API_PORT" ]; then
    PROBE_PORT=$(free_port)
    while [ "$PROBE_PORT" = "$STATS_API_PORT" ]; do PROBE_PORT=$(free_port); done
    sed -i '/^PROBE_PORT=/d' "$STATE/a.env"; echo "PROBE_PORT=$PROBE_PORT" >> "$STATE/a.env"
  fi
  chmod 600 "$STATE/a.env"
}

# 把统计/探测结构同步进配置文件 $1（原地改写，幂等）。
#   $2=1：没启用也强制加上（部署 / 升级用）；$2=0：只在已启用时同步（加删节点 / 迁移用）
# 同步内容：api/stats/policy、节点 email、bridge email、每节点一个探测账号 + 一条探测路由，
# 删掉已不存在节点的探测账号/路由，探测路由的出口永远跟节点路由一致。
stats_sync(){
  local f="$1" force="${2:-0}" out rc=0
  out=$(mktemp --suffix=.json)
  ATT_CFG="$f" ATT_FORCE="$force" API_PORT="${STATS_API_PORT:-}" PRB_PORT="${PROBE_PORT:-}" \
    python3 - > "$out" <<'PY' || rc=$?
import json,os,secrets,sys
d=json.load(open(os.environ['ATT_CFG']))
ibs=d.setdefault('inbounds',[])
has=bool((d.get('api') or {}).get('listen')) and any(ib.get('tag')=='probe-in' for ib in ibs)
if not has and os.environ.get('ATT_FORCE')!='1':
    print(json.dumps(d,indent=1)); sys.exit(0)
ap=os.environ.get('API_PORT',''); pp=os.environ.get('PRB_PORT','')
# 已启用时沿用配置里的端口，只有新增时才需要端口参数
if not has and not (ap.isdigit() and pp.isdigit()):
    raise SystemExit('NOPORT')
if not (d.get('api') or {}).get('listen'):
    d['api']={'tag':'api','listen':'127.0.0.1:%s'%ap,'services':['StatsService']}
d.setdefault('stats',{})
pol=d.setdefault('policy',{})
lv=pol.setdefault('levels',{}).setdefault('0',{})
lv['statsUserUplink']=True; lv['statsUserDownlink']=True
sy=pol.setdefault('system',{})
for k in ('statsInboundUplink','statsInboundDownlink','statsOutboundUplink','statsOutboundDownlink'):
    sy[k]=True
rules=d.setdefault('routing',{}).setdefault('rules',[])
def is_probe(r): return 'probe-in' in (r.get('inboundTag') or [])
nodes=[]
for ib in ibs:
    if ib.get('tag')=='user-in' or str(ib.get('tag','')).startswith('user-in-'):
        for i,c in enumerate(ib.get('settings',{}).get('clients',[])):
            if not c.get('email'):
                c['email']='node' if i==0 else 'node%d'%(i+1)
            nodes.append(c['email'])
for ib in ibs:
    if ib.get('tag')=='reverse-in':
        for c in ib.get('settings',{}).get('clients',[]):
            t=(c.get('reverse') or {}).get('tag')
            if t:
                c['email']='exit.%s'%t
n2p={}
for r in rules:
    ot=r.get('outboundTag','')
    if ot.startswith('portal') and not is_probe(r):
        for u in r.get('user',[]):
            n2p.setdefault(u,ot)
pin=[ib for ib in ibs if ib.get('tag')=='probe-in']
if pin:
    pin=pin[0]
else:
    pin={'tag':'probe-in','listen':'127.0.0.1','port':int(pp),'protocol':'socks',
         'settings':{'auth':'password','accounts':[],'udp':False}}
    ibs.append(pin)
pin['listen']='127.0.0.1'
st=pin.setdefault('settings',{}); st['auth']='password'; st['udp']=False
old={a.get('user'):a.get('pass') for a in st.get('accounts',[]) if a.get('pass')}
st['accounts']=[{'user':'probe-'+n,'pass':old.get('probe-'+n) or secrets.token_hex(16)} for n in nodes]
if not st['accounts']:
    raise SystemExit('NONODE')
obs=d.setdefault('outbounds',[])
if not any(o.get('tag')=='probe-block' for o in obs):
    obs.append({'tag':'probe-block','protocol':'blackhole'})
keep=[r for r in rules if not is_probe(r)]
pr=[{'type':'field','inboundTag':['probe-in'],'user':['probe-'+n],'outboundTag':n2p[n]} for n in nodes if n in n2p]
pr.append({'type':'field','inboundTag':['probe-in'],'outboundTag':'probe-block'})
d['routing']['rules']=pr+keep
print(json.dumps(d,indent=1))
PY
  if [ "$rc" != 0 ] || [ ! -s "$out" ]; then rm -f "$out"; return 1; fi
  mv "$out" "$f"
}

# 已部署的 A 端升级：加上统计 + 出口探测。幂等，可反复跑。
# 先备份，xray -test + validate_cfg 都过了才替换；服务起不来 apply_cfg 自动回滚。
enable_stats(){
  need_root
  [ -f "$STATE/a.env" ] || die "只有 A 端（入口机）需要启用统计"
  [ -f "$CFG" ] || die "找不到配置 $CFG"
  ensure_migrated
  ensure_stats_ports
  local tmp; tmp=$(mktemp --suffix=.json)
  cp "$CFG" "$tmp"
  stats_sync "$tmp" 1 || { rm -f "$tmp"; die "统计配置生成失败（原配置未改动）"; }
  if ATT_A="$CFG" ATT_B="$tmp" python3 -c 'import json,os,sys; a=json.load(open(os.environ["ATT_A"])); b=json.load(open(os.environ["ATT_B"])); sys.exit(0 if a==b else 1)'; then
    rm -f "$tmp"; ok "流量统计 / 出口探测已启用，配置无需改动"; return 0
  fi
  "$XRAY_BIN" -test -config "$tmp" >/dev/null 2>&1 || {
    "$XRAY_BIN" -test -config "$tmp" 2>&1 | tail -5; rm -f "$tmp"
    die "新配置 xray -test 不通过（原配置未改动）"; }
  local vmsg
  if ! vmsg=$(validate_cfg "$tmp"); then
    rm -f "$tmp"; echo "$vmsg" | sed 's/^/    /'
    die "新配置自检不通过（原配置未改动）"
  fi
  warn "将重启 att-tunnel，连接会断几秒（分享链接、B 端都不变）"
  apply_cfg "$tmp"
  ok "已启用流量统计（API 仅监听 127.0.0.1:$STATS_API_PORT）和出口探测（127.0.0.1:$PROBE_PORT）"
  systemctl is-active --quiet "$WEB_SVC" 2>/dev/null && systemctl restart "$WEB_SVC" || true
}

# ================= 网页流量面板（A 端） =================
WEB_SVC="att-tunnel-web"
WEB_DIR="/usr/local/lib/att-tunnel"
WEB_PY="$WEB_DIR/web.py"
WEB_SCRIPT="$WEB_DIR/att-tunnel.sh"
WEB_ENV="$STATE/web.env"
WEB_DATA="/var/lib/att-tunnel"

write_web_py(){
  mkdir -p "$WEB_DIR"
  cat > "$WEB_PY.tmp" <<'ATT_WEB_PY'
#!/usr/bin/env python3
# att-tunnel 网页面板 vATT_VERSION：只用 Python 标准库，无外部 CDN。
# 流量：每 POLL 秒读一次 Xray StatsService 的累计计数（不 -reset），按差值累加进本地 JSON。
#   每个节点两路计数取大者：客户端计数 user>>>节点 和 出口隧道计数 user>>>exit.<portal>
#   （出口隧道计数扣掉探测流量；多节点共用 portal 的旧结构只用客户端计数）。
# 出口 IP：经 127.0.0.1 的 probe-in（socks5+密码）按节点走 portal-<节点>，访问 api.ipify.org。
# 加/删节点：调用本机脚本副本 att-tunnel.sh --add/--del（同一套配置逻辑、校验和回滚），不在这里改配置。
# 安全：随机端口 + 随机路径 + 密码；Cookie HttpOnly/SameSite=Strict；所有 POST 需会话 + CSRF；
#       登录失败限速；分享链接/UUID 只在「查看链接」时按需返回，状态接口里没有。
import hmac
import http.cookies
import http.server
import ipaddress
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import threading
import time
import traceback
import urllib.parse

VERSION = 'ATT_VERSION'
CFG = os.environ.get('ATT_CFG', '/usr/local/etc/att-tunnel/config.json')
ENVF = os.environ.get('ATT_WEB_ENV', '/etc/att-tunnel/web.env')
AENV = os.environ.get('ATT_A_ENV', '/etc/att-tunnel/a.env')
STATEF = os.environ.get('ATT_WEB_STATE', '/var/lib/att-tunnel/web-state.json')
XRAY = os.environ.get('ATT_XRAY', '/usr/local/bin/xray')
SCRIPT = os.environ.get('ATT_SCRIPT', '/usr/local/lib/att-tunnel/att-tunnel.sh')
SVC = os.environ.get('ATT_SVC', 'att-tunnel')
POLL = int(os.environ.get('ATT_POLL', '10'))
PROBE_EVERY = int(os.environ.get('ATT_PROBE_EVERY', '300'))
HIST_MAX = 90           # 每节点保留最近 90 个采样点（默认 10s 一个 = 15 分钟）
SESSION_TTL = 12 * 3600
IP_SOURCES = [('api.ipify.org', '/'), ('icanhazip.com', '/'), ('ifconfig.me', '/ip')]
NAME_RE = re.compile(r'^[A-Za-z0-9_-]{1,32}$')     # 与脚本 add_node 同一规则
SNI_RE = re.compile(r'^[A-Za-z0-9.-]{1,253}$')
ANSI_RE = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]')


def log(*a):
    print(time.strftime('%F %T'), *a, file=sys.stderr, flush=True)


def load_env(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                k, v = line.split('=', 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return env


ENV = load_env(ENVF)
PORT = int(ENV['WEB_PORT'])
PREFIX = '/' + ENV['WEB_PATH'].strip('/')
PASS = ENV['WEB_PASS']
LISTEN = ENV.get('WEB_LISTEN', '0.0.0.0')
RAW_URL = ENV.get('WEB_RAW_URL', '')
if len(PASS) < 8 or PREFIX == '/':
    sys.exit('web.env 不完整：WEB_PASS 至少 8 位，WEB_PATH 不能为空')

lock = threading.RLock()
save_lock = threading.Lock()
probe_lock = threading.Lock()
mut_lock = threading.Lock()      # 加/删节点串行（脚本里还有一把 flock）
state = {'nodes': {}, 'raw': {}, 'last_poll': 0, 'poll_err': '', 'started': 0}


def now():
    return int(time.time())


def load_state():
    global state
    try:
        with open(STATEF) as f:
            s = json.load(f)
        if isinstance(s, dict) and isinstance(s.get('nodes'), dict):
            s.setdefault('raw', {})
            # v2.1.0 每次都 -reset，它留下的计数基线没有意义
            if s.get('ver') != 2:
                s['raw'] = {}
            state.update(s)
    except Exception:
        pass
    state['ver'] = 2


def save_state():
    # v2.1.0 的 bug：多线程共用一个临时文件名，并发保存会抛 FileNotFoundError，
    # 而轮询线程没接住这个异常 -> 统计线程静默退出，流量从此不再增长。
    # 现在：串行保存 + 每线程独立临时名 + 调用方全部 try 住。
    with save_lock:
        d = os.path.dirname(STATEF)
        os.makedirs(d, mode=0o700, exist_ok=True)
        tmp = '%s.tmp.%d.%d' % (STATEF, os.getpid(), threading.get_ident())
        with lock:
            data = json.dumps(state, ensure_ascii=False)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, STATEF)


def safe_save():
    try:
        save_state()
    except Exception as e:
        log('保存状态失败:', e)


def is_user_in(ib):
    t = str(ib.get('tag', ''))
    return t == 'user-in' or t.startswith('user-in-')


def read_cfg():
    """从 config.json 读节点表：名称、入口端口、伪装域名、绑定出口、探测账号、API 地址。"""
    with open(CFG) as f:
        d = json.load(f)
    api = (d.get('api') or {}).get('listen', '')
    nodes, probe_port, probe_acc = [], None, {}
    for ib in d.get('inbounds', []):
        if is_user_in(ib):
            rs = (ib.get('streamSettings') or {}).get('realitySettings') or {}
            sni = (rs.get('serverNames') or [''])[0]
            for c in ib.get('settings', {}).get('clients', []):
                nodes.append((c.get('email', 'node'), ib.get('port'), sni))
        elif ib.get('tag') == 'probe-in':
            probe_port = ib.get('port')
            for a in ib.get('settings', {}).get('accounts', []):
                probe_acc[a.get('user', '')] = a.get('pass', '')
    portal = {}
    for r in d.get('routing', {}).get('rules', []):
        ot = r.get('outboundTag', '')
        if ot.startswith('portal') and 'probe-in' not in (r.get('inboundTag') or []):
            for u in r.get('user', []):
                portal[u] = ot
    use = {}
    for n, _, _ in nodes:
        if portal.get(n):
            use[portal[n]] = use.get(portal[n], 0) + 1
    out = []
    for n, port, sni in nodes:
        ex = portal.get(n, '')
        out.append({'name': n, 'port': port, 'sni': sni, 'exit': ex,
                    'shared': use.get(ex, 0) > 1,
                    'probe_user': 'probe-' + n,
                    'probe_pass': probe_acc.get('probe-' + n, '')})
    return {'api': api, 'probe_port': probe_port, 'nodes': out}


def node_rec(name):
    with lock:
        r = state['nodes'].setdefault(name, {})
        for k, v in (('up', 0), ('down', 0), ('since', now()), ('ip', ''), ('ip_ts', 0),
                     ('probe_ok', False), ('probe_ts', 0), ('probe_err', ''), ('hist', []),
                     ('rate_up', 0), ('rate_down', 0), ('cnt_user', 0), ('cnt_exit', 0)):
            r.setdefault(k, v)
        return r


def statsquery(api):
    """读全部累计计数（不清零）。返回 {计数器名: 值}。值为 0 的计数器 Xray 不输出 value 字段。"""
    p = subprocess.run([XRAY, 'api', 'statsquery', '--server=' + api],
                       capture_output=True, text=True, timeout=15)
    if p.returncode != 0:
        raise RuntimeError('xray api statsquery 失败：' +
                           ((p.stderr or p.stdout).strip()[-200:] or 'rc=%d' % p.returncode))
    txt = p.stdout.strip()
    if not txt:
        return {}
    return {s.get('name', ''): int(s.get('value') or 0) for s in (json.loads(txt).get('stat') or [])}


def svc_info(name):
    """(是否 active, 进入 active 的单调时间戳)。时间戳变了 = xray 重启过，计数器已归零。"""
    try:
        p = subprocess.run(['systemctl', 'show', name, '-p', 'ActiveState',
                            '-p', 'ActiveEnterTimestampMonotonic', '-p', 'ActiveEnterTimestamp'],
                           capture_output=True, text=True, timeout=5)
        kv = dict(l.split('=', 1) for l in p.stdout.splitlines() if '=' in l)
        return (kv.get('ActiveState') == 'active', kv.get('ActiveEnterTimestampMonotonic', ''),
                kv.get('ActiveEnterTimestamp', ''))
    except Exception:
        return (False, '', '')


def poll_stats():
    """读累计计数，按差值累加。xray 重启（计数归零）靠 systemd 的启动时间戳识别。"""
    try:
        c = read_cfg()
        if not c['api']:
            raise RuntimeError('config.json 没有 api 段：请重跑 --web（会自动启用统计并重启 xray）')
        active, mono, since = svc_info(SVC)
        with lock:
            state['xray_active'], state['xray_since'] = active, since
        if not active:
            raise RuntimeError('%s 服务未运行，读不到流量计数' % SVC)
        cur = statsquery(c['api'])
        t = now()
        with lock:
            if state.get('xray_mono') != mono:
                state['raw'] = {}          # xray 重启过：新计数从 0 开始
                state['xray_mono'] = mono
            raw = state['raw']
            dl = {k: (v - raw[k] if k in raw and v >= raw[k] else v) for k, v in cur.items()}
            state['raw'] = cur
            dt = max(1, t - (state.get('last_poll') or t - POLL))
            for n in c['nodes']:
                name, ex = n['name'], n['exit']
                r = node_rec(name)
                u_up = dl.get('user>>>%s>>>traffic>>>uplink' % name, 0)
                u_dn = dl.get('user>>>%s>>>traffic>>>downlink' % name, 0)
                e_up = e_dn = 0
                if ex and not n['shared']:
                    # 出口隧道的方向与客户端相反：B->A(uplink) 就是用户下载
                    p_up = dl.get('user>>>probe-%s>>>traffic>>>uplink' % name, 0)
                    p_dn = dl.get('user>>>probe-%s>>>traffic>>>downlink' % name, 0)
                    e_dn = max(0, dl.get('user>>>exit.%s>>>traffic>>>uplink' % ex, 0) - p_dn)
                    e_up = max(0, dl.get('user>>>exit.%s>>>traffic>>>downlink' % ex, 0) - p_up)
                up, dn = max(u_up, e_up), max(u_dn, e_dn)
                r['up'] += up
                r['down'] += dn
                r['cnt_user'] += u_up + u_dn
                r['cnt_exit'] += e_up + e_dn
                r['rate_up'], r['rate_down'] = up // dt, dn // dt
                r['hist'] = (r['hist'] + [[t, up, dn]])[-HIST_MAX:]
            state['last_poll'] = t
            state['poll_err'] = ''
    except Exception as e:
        with lock:
            state['poll_err'] = str(e)[:300]
        log('统计轮询失败:', e)
    safe_save()


def recv_exact(s, n):
    b = b''
    while len(b) < n:
        x = s.recv(n - len(b))
        if not x:
            raise RuntimeError('socks 连接被关闭')
        b += x
    return b


def socks5_get(port, user, pw, host, path, timeout=12):
    """标准库 socks5（RFC1928/1929 密码认证）+ 明文 HTTP GET，返回响应体。"""
    s = socket.create_connection(('127.0.0.1', port), timeout=timeout)
    try:
        s.sendall(b'\x05\x01\x02')
        if recv_exact(s, 2) != b'\x05\x02':
            raise RuntimeError('socks 不接受密码认证')
        u, p = user.encode(), pw.encode()
        s.sendall(b'\x01' + bytes([len(u)]) + u + bytes([len(p)]) + p)
        if recv_exact(s, 2)[1] != 0:
            raise RuntimeError('socks 认证失败')
        h = host.encode()
        s.sendall(b'\x05\x01\x00\x03' + bytes([len(h)]) + h + (80).to_bytes(2, 'big'))
        rep = recv_exact(s, 4)
        if rep[1] != 0:
            raise RuntimeError('socks 连接失败 rep=%d' % rep[1])
        atyp = rep[3]
        if atyp == 1:
            recv_exact(s, 6)
        elif atyp == 4:
            recv_exact(s, 18)
        else:
            recv_exact(s, recv_exact(s, 1)[0] + 2)
        req = ('GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: curl/8.0\r\n'
               'Accept: */*\r\nConnection: close\r\n\r\n' % (path, host))
        s.sendall(req.encode())
        buf = b''
        while len(buf) < 65536:
            x = s.recv(4096)
            if not x:
                break
            buf += x
    finally:
        s.close()
    head, _, body = buf.partition(b'\r\n\r\n')
    status = head.split(b'\r\n', 1)[0]
    if b' 200' not in status:
        raise RuntimeError('HTTP ' + status.decode('latin1')[:40] if status else '出口无响应（隧道未连上？）')
    return body.decode('latin1').strip()


def probe_node(n, probe_port):
    r = node_rec(n['name'])
    err, ip = '', ''
    if not probe_port or not n['probe_pass']:
        err = '未配置探测账号（重跑 --web）'
    elif not n['exit']:
        err = '节点没绑定出口机'
    else:
        for host, path in IP_SOURCES:
            try:
                txt = socks5_get(probe_port, n['probe_user'], n['probe_pass'], host, path)
                ip = str(ipaddress.ip_address(txt.split()[0]))
                break
            except Exception as e:
                err = '%s: %s' % (host, str(e)[:80])
    with lock:
        r['probe_ts'] = now()
        if ip:
            r['ip'], r['ip_ts'], r['probe_ok'], r['probe_err'] = ip, now(), True, ''
        else:
            r['probe_ok'], r['probe_err'] = False, err


def probe_all(only=None, wait=True):
    if not probe_lock.acquire(blocking=wait):
        return False  # 已有一轮在跑
    try:
        c = read_cfg()
        ths = []
        for n in c['nodes']:
            if only and n['name'] != only:
                continue
            t = threading.Thread(target=probe_node, args=(n, c['probe_port']), daemon=True)
            t.start()
            ths.append(t)
        for t in ths:
            t.join(60)
    except Exception as e:
        log('探测失败:', e)
    finally:
        probe_lock.release()
    safe_save()
    return True


def worker():
    last_probe = 0
    while True:
        # 任何异常都不能让这个线程退出（v2.1.0 就是线程静默死掉，流量永远不再增长）
        try:
            poll_stats()
            if time.time() - last_probe >= PROBE_EVERY:
                last_probe = time.time()
                threading.Thread(target=probe_all, kwargs={'wait': False}, daemon=True).start()
        except Exception:
            log('worker 异常:', traceback.format_exc())
        time.sleep(POLL)


def tunnel_count(port):
    """数 reverse-in 端口上的 ESTABLISHED 连接（= 已连上的出口机隧道数）。"""
    n = 0
    for fn in ('/proc/net/tcp', '/proc/net/tcp6'):
        try:
            with open(fn) as f:
                next(f)
                for line in f:
                    p = line.split()
                    if p[3] == '01' and int(p[1].rsplit(':', 1)[1], 16) == port:
                        n += 1
        except Exception:
            pass
    return n


def status_json():
    try:
        c = read_cfg()
        cfg_err = ''
    except Exception as e:
        c, cfg_err = {'nodes': []}, '读配置失败：' + str(e)[:200]
    a = load_env(AENV)
    t = now()
    out = []
    with lock:
        for n in c['nodes']:
            r = node_rec(n['name'])
            online = bool(r['probe_ok'] and t - r['probe_ts'] <= PROBE_EVERY + 2 * POLL + 60)
            out.append({'name': n['name'], 'port': n['port'], 'sni': n['sni'], 'exit': n['exit'],
                        'shared': n['shared'], 'online': online, 'ip': r['ip'], 'ip_ts': r['ip_ts'],
                        'probe_ts': r['probe_ts'], 'probe_err': r['probe_err'],
                        'up': r['up'], 'down': r['down'], 'total': r['up'] + r['down'],
                        'rate_up': r['rate_up'], 'rate_down': r['rate_down'],
                        'hist': [h[1] + h[2] for h in r['hist'][-40:]],
                        'src_user': r['cnt_user'], 'src_exit': r['cnt_exit'], 'since': r['since']})
        rp = a.get('REVERSE_PORT', '')
        return {'now': t, 'version': VERSION, 'a_ip': a.get('A_IP', ''),
                'reverse_port': rp, 'tunnels': tunnel_count(int(rp)) if rp.isdigit() else 0,
                'xray_active': state.get('xray_active', False), 'xray_since': state.get('xray_since', ''),
                'last_poll': state['last_poll'], 'poll': POLL, 'probe_every': PROBE_EVERY,
                'error': cfg_err or state['poll_err'], 'nodes': out, 'busy': mut_lock.locked(), 'manage': os.path.isfile(SCRIPT)}


def run_script(args, extra_env=None, timeout=180):
    """非交互调用脚本副本。返回 (rc, 去掉颜色码的输出)。"""
    if not os.path.isfile(SCRIPT):
        return 127, '找不到脚本副本 %s：请在 A 机上重跑一次 --web' % SCRIPT
    env = {'PATH': '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin',
           'HOME': '/root', 'LANG': 'C.UTF-8', 'ATT_NONINTERACTIVE': '1', 'ATT_FROM_WEB': '1'}
    if RAW_URL:
        env['ATT_RAW_URL'] = RAW_URL
    env.update(extra_env or {})
    try:
        p = subprocess.run(['bash', SCRIPT] + args, stdin=subprocess.DEVNULL, capture_output=True,
                           text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return 124, '脚本执行超时（%ds）' % timeout
    txt = ANSI_RE.sub('', (p.stdout or '') + (p.stderr or ''))
    return p.returncode, txt.strip()[-6000:]


SNI_PRESETS = "ATT_SNI_PRESETS"   # write_web_py 替换成脚本里的预置列表 [[域名, 国家], ...]


def node_names():
    try:
        return [x['name'] for x in read_cfg()['nodes']]
    except Exception:
        return []


def node_link(name):
    """按需取分享链接 + 出口机命令（都来自脚本本身）。"""
    rc, out = run_script(['--link', name], timeout=30)
    link = next((l.strip() for l in out.splitlines() if l.strip().startswith('vless://')), '')
    if rc != 0 or not link:
        raise RuntimeError(out or '取分享链接失败')
    rc, out = run_script(['--exit-cmd', name], timeout=30)
    cmd = next((l.strip() for l in out.splitlines() if '--bridge ' in l), '')
    if rc != 0 or not cmd:
        raise RuntimeError(out or '取出口机命令失败')
    return {'name': name, 'link': link, 'exit_cmd': cmd}


def after_change(name=None):
    """加/删节点后：清理已删节点的记录，立刻轮询一次，并探测新节点。"""
    keep = set(node_names())
    with lock:
        for k in [k for k in state['nodes'] if k not in keep]:
            del state['nodes'][k]
    poll_stats()
    if name and name in keep:
        threading.Thread(target=probe_all, kwargs={'only': name}, daemon=True).start()


sessions = {}   # sid -> {'exp': ts, 'csrf': token}
fails = {}      # ip -> [失败时间戳]
FAIL_WIN, FAIL_MAX = 600, 5


def rate_limited(ip):
    t = time.time()
    with lock:
        lst = [x for x in fails.get(ip, []) if t - x < FAIL_WIN]
        fails[ip] = lst
        return len(lst) >= FAIL_MAX


def note_fail(ip):
    with lock:
        fails.setdefault(ip, []).append(time.time())


def new_session():
    sid, csrf = secrets.token_urlsafe(32), secrets.token_urlsafe(24)
    with lock:
        t = time.time()
        for k in [k for k, v in sessions.items() if v['exp'] < t]:
            del sessions[k]
        sessions[sid] = {'exp': t + SESSION_TTL, 'csrf': csrf}
    return sid


CSS = '''
:root{--bg:#f3f5f9;--card:#fff;--fg:#0f172a;--mut:#64748b;--line:#e2e8f0;--pri:#2563eb;--pri2:#1d4ed8;
--ok:#16a34a;--okb:#dcfce7;--bad:#dc2626;--badb:#fee2e2;--warn:#b45309;--warnb:#fef3c7;--sh:0 1px 3px #0f172a14,0 4px 16px #0f172a0d}
@media(prefers-color-scheme:dark){:root{--bg:#0b1020;--card:#141b2d;--fg:#e2e8f0;--mut:#94a3b8;--line:#243049;
--pri:#3b82f6;--pri2:#60a5fa;--ok:#4ade80;--okb:#14532d66;--bad:#f87171;--badb:#7f1d1d66;--warn:#fbbf24;--warnb:#78350f66;--sh:0 1px 3px #0006}}
*{box-sizing:border-box}html,body{margin:0}body{font:15px/1.5 system-ui,-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;background:var(--bg);color:var(--fg)}
button,input,select{font:inherit;color:inherit}
.btn{border:1px solid var(--line);background:var(--card);padding:8px 14px;border-radius:10px;cursor:pointer;white-space:nowrap}
.btn:hover{border-color:var(--pri)}.btn:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--pri);outline-offset:2px}
.btn.p{background:var(--pri);border-color:var(--pri);color:#fff}.btn.p:hover{background:var(--pri2)}
.btn.d{color:var(--bad)}.btn.d:hover{border-color:var(--bad)}.btn.s{padding:5px 10px;font-size:13px}
.btn:disabled{opacity:.55;cursor:not-allowed}
input,select{width:100%;padding:9px 11px;border:1px solid var(--line);border-radius:10px;background:var(--bg)}
label{display:block;font-size:13px;color:var(--mut);margin:10px 0 4px}
.card{background:var(--card);border:1px solid var(--line);border-radius:16px;box-shadow:var(--sh)}
.mut{color:var(--mut)}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:13px;word-break:break-all}
.err{color:var(--bad)}
'''

PAGE_LOGIN = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">
<title>att-tunnel 登录</title><style>{CSS}
body{min-height:100vh;display:flex;align-items:center;justify-content:center;padding:16px}
form{width:min(360px,100%);padding:28px}h1{font-size:20px;margin:0 0 4px}.logo{font-size:28px}
.btn{width:100%;margin-top:16px;padding:11px}</style></head>
<body><form class="card" method="post" action="{P}/login"><div class="logo" aria-hidden="true">🛰️</div>
<h1>att-tunnel 面板</h1><p class="mut" style="margin:0 0 8px">反向隧道 · 流量与节点管理</p>{E}
<label for="pw">密码</label><input id="pw" type="password" name="password" autocomplete="current-password" required autofocus>
<button class="btn p" type="submit">登录</button></form></body></html>'''

PAGE_MAIN = '''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light dark">
<title>att-tunnel 面板</title><style>{CSS}
.wrap{max-width:1180px;margin:0 auto;padding:16px}
header{display:flex;flex-wrap:wrap;gap:12px;align-items:center;justify-content:space-between;padding:16px 20px;margin-bottom:16px}
header h1{font-size:19px;margin:0}.hinfo{display:flex;flex-wrap:wrap;gap:6px 16px;font-size:13px}
.acts{display:flex;gap:8px;flex-wrap:wrap}
.pill{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:999px;font-size:12px;font-weight:600}
.pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.pill.on{color:var(--ok);background:var(--okb)}.pill.off{color:var(--bad);background:var(--badb)}.pill.w{color:var(--warn);background:var(--warnb)}
.sum{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-bottom:16px}
.sum .card{padding:14px 16px}.sum b{display:block;font-size:24px;font-weight:700;margin-top:2px}
.alert{padding:12px 16px;margin-bottom:16px;border-color:var(--bad);color:var(--bad);background:var(--badb);display:none;white-space:pre-wrap}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}
.node{padding:16px}.node h2{font-size:17px;margin:0;display:flex;align-items:center;justify-content:space-between;gap:8px}
.kv{display:grid;grid-template-columns:auto 1fr;gap:4px 12px;margin:12px 0;font-size:14px}.kv dt{color:var(--mut)}.kv dd{margin:0;word-break:break-all}
.tr{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin:8px 0}.tr div{background:var(--bg);border-radius:10px;padding:8px 10px}
.tr small{color:var(--mut);display:block;font-size:12px}.tr b{font-size:16px}
.barw{height:6px;background:var(--bg);border-radius:9px;overflow:hidden;margin:6px 0 2px}.bar{height:100%;background:linear-gradient(90deg,var(--pri),#8b5cf6);border-radius:9px}
svg.spark{width:100%;height:34px;display:block}svg.spark path{fill:none;stroke:var(--pri);stroke-width:1.5}
.nact{display:flex;gap:6px;flex-wrap:wrap;margin-top:10px}
.sec{display:flex;align-items:center;justify-content:space-between;margin:20px 0 10px}.sec h3{margin:0;font-size:16px}
.empty{padding:30px;text-align:center}
dialog{border:1px solid var(--line);border-radius:16px;background:var(--card);color:var(--fg);padding:0;width:min(560px,94vw);box-shadow:var(--sh)}
dialog::backdrop{background:#0008}.dh{padding:16px 20px;border-bottom:1px solid var(--line);font-weight:700}
.db{padding:4px 20px 16px}.df{padding:12px 20px;border-top:1px solid var(--line);display:flex;gap:8px;justify-content:flex-end}
.row{display:flex;gap:8px}.row>*{flex:1}
.copy{display:flex;gap:6px;align-items:flex-start;background:var(--bg);border-radius:10px;padding:8px 10px;margin-top:4px}.copy .mono{flex:1}
pre.out{max-height:220px;overflow:auto;background:var(--bg);padding:10px;border-radius:10px;font-size:12px;white-space:pre-wrap}
#toasts{position:fixed;right:16px;bottom:16px;display:flex;flex-direction:column;gap:8px;z-index:9;max-width:min(380px,90vw)}
.toast{padding:10px 14px;border-radius:12px;color:#fff;background:#0f172a;box-shadow:var(--sh);font-size:14px}
.toast.ok{background:#15803d}.toast.bad{background:#b91c1c}
@media(max-width:760px){.sum{grid-template-columns:repeat(2,1fr)}.sum .card:last-child{grid-column:1/-1}.wrap{padding:10px}header{padding:14px}}
</style></head><body><div class="wrap">
<header class="card"><div><h1>🛰️ att-tunnel 面板 <span class="mut" style="font-size:13px;font-weight:400" id="ver"></span></h1>
<div class="hinfo mut" id="hinfo">加载中…</div></div>
<div class="acts"><button class="btn p" id="bAdd" type="button" hidden>＋ 添加节点</button>
<button class="btn" id="bProbe" type="button">立即探测</button><button class="btn" id="bRef" type="button">刷新</button>
<form method="post" action="{P}/logout" style="margin:0"><input type="hidden" name="csrf" value="{C}"><button class="btn" type="submit">退出</button></form></div></header>
<div class="card alert" id="err" role="alert"></div>
<div class="sum" id="sum"></div>
<div class="sec"><h3>节点</h3><span class="mut" style="font-size:13px" id="meta" aria-live="polite"></span></div>
<div class="grid" id="list"></div></div>
<div id="toasts" aria-live="polite"></div>
'''
PAGE_MAIN += '''
<dialog id="dAdd" aria-labelledby="dAddH"><form id="fAdd" method="dialog"><div class="dh" id="dAddH">添加节点</div><div class="db">
<label for="aName">节点名称（字母/数字/下划线/连字符，最多 32 位）</label><input id="aName" name="name" required maxlength="32" pattern="[A-Za-z0-9_-]{1,32}" placeholder="如 LA2" autocomplete="off">
<label for="aPort">入口端口（留空 = 与主入口共用 <span id="defPort"></span>）</label><input id="aPort" name="port" inputmode="numeric" pattern="[0-9]{1,5}" placeholder="留空即可">
<label for="aSni">伪装域名（只在单独端口时生效；共用端口时沿用主入口的 <span id="defSni"></span>）</label><select id="aSni" name="sni"></select>
<div id="aCustW" hidden><label for="aCust">自定义域名（需支持 TLS 1.3）</label><input id="aCust" placeholder="www.example.com" autocomplete="off"></div>
<p class="mut" style="font-size:13px">添加会重启 att-tunnel，已有连接断开几秒。失败会自动回滚。</p></div>
<div class="df"><button class="btn" type="button" data-close>取消</button><button class="btn p" type="submit" id="aGo">添加</button></div></form></dialog>
<dialog id="dRes" aria-labelledby="dResH"><div class="dh" id="dResH">节点信息</div><div class="db" id="resB"></div>
<div class="df"><button class="btn p" type="button" data-close>关闭</button></div></dialog>
<dialog id="dDel" aria-labelledby="dDelH"><form id="fDel" method="dialog"><div class="dh" id="dDelH">删除节点</div><div class="db">
<p>删除后节点 <b id="delN"></b> 的分享链接立即失效，它的出口机会失去连接（需自己去出口机卸载）。</p>
<label for="delIn">请输入节点名确认</label><input id="delIn" autocomplete="off" required></div>
<div class="df"><button class="btn" type="button" data-close>取消</button><button class="btn d" type="submit" id="delGo" disabled>删除</button></div></form></dialog>
<dialog id="dOut" aria-labelledby="dOutH"><div class="dh err" id="dOutH">操作失败</div><div class="db"><p id="outMsg"></p><pre class="out" id="outTxt"></pre></div>
<div class="df"><button class="btn p" type="button" data-close>关闭</button></div></dialog>
<script>
const P="{P}",C="{C}",SNIS={SNIS};let D=null,busy=false;
const $=i=>document.getElementById(i);
function fb(n){n=+n||0;const u=["B","KB","MB","GB","TB","PB"];let i=0;while(n>=1024&&i<5){n/=1024;i++}return(i?n.toFixed(n<10?2:n<100?1:0):n)+" "+u[i]}
function ago(t){if(!t)return"从未";const s=Math.max(0,Math.floor(Date.now()/1000)-t);if(s<60)return s+" 秒前";if(s<3600)return Math.floor(s/60)+" 分钟前";if(s<86400)return Math.floor(s/3600)+" 小时前";return new Date(t*1000).toLocaleString("zh-CN",{hour12:false})}
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]))}
function toast(m,k){const e=document.createElement("div");e.className="toast "+(k||"");e.textContent=m;$("toasts").appendChild(e);setTimeout(()=>e.remove(),k=="bad"?7000:3500)}
function fail(msg,out){$("outMsg").textContent=msg;$("outTxt").textContent=out||"";$("outTxt").hidden=!out;$("dOut").showModal()}
async function post(u,body){const r=await fetch(P+u,{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded","X-CSRF-Token":C},body:new URLSearchParams(body||{})});
if(r.status==401){location.href=P+"/";throw new Error("登录已过期")}let j={};try{j=await r.json()}catch(e){}if(!r.ok||!j.ok){const e=new Error(j.error||("HTTP "+r.status));e.out=j.output||"";throw e}return j}
function spark(h){if(!h||h.length<2)return"";const m=Math.max(1,...h),w=100/(h.length-1);return`<svg class="spark" viewBox="0 0 100 34" preserveAspectRatio="none" aria-hidden="true"><path d="${h.map((v,i)=>(i?"L":"M")+(i*w).toFixed(1)+" "+(32-v/m*30).toFixed(1)).join(" ")}"/></svg>`}
'''
PAGE_MAIN += '''
function render(d){D=d;busy=d.busy;
$("ver").textContent="v"+d.version;
const xs=d.xray_active?'<span class="pill on">xray 运行中</span>':'<span class="pill off">xray 未运行</span>';
$("hinfo").innerHTML=`<span>A 机 <b class="mono">${esc(d.a_ip)}</b></span><span>反代口 ${esc(d.reverse_port)}</span><span>隧道连接 ${d.tunnels}</span>${xs}`;
const e=$("err");if(d.error){e.style.display="block";e.textContent="⚠ 统计异常："+d.error}else e.style.display="none";
const on=d.nodes.filter(n=>n.online).length,up=d.nodes.reduce((a,n)=>a+n.up,0),dn=d.nodes.reduce((a,n)=>a+n.down,0);
$("sum").innerHTML=[["节点",d.nodes.length],["在线",on+" / "+d.nodes.length],["总上传",fb(up)],["总下载",fb(dn)],["总流量",fb(up+dn)]].map(x=>`<div class="card"><span class="mut">${x[0]}</span><b>${x[1]}</b></div>`).join("");
const age=d.last_poll?d.now-d.last_poll:-1;
$("meta").textContent=d.last_poll?("流量更新于 "+ago(d.last_poll)+"（每 "+d.poll+" 秒）"+(age>3*d.poll+5?" · 已停止更新！":"")):"尚未取到流量";
const mx=Math.max(1,...d.nodes.map(n=>n.total));
$("list").innerHTML=d.nodes.map(n=>{const st=n.online?'<span class="pill on">在线</span>':(n.probe_ts?'<span class="pill off">离线</span>':'<span class="pill w">待探测</span>');
return`<section class="card node"><h2><span>${esc(n.name)}</span>${st}</h2><dl class="kv">
<dt>出口 IP</dt><dd class="mono">${esc(n.ip||"—")}</dd><dt>最后探测</dt><dd>${ago(n.probe_ts)}${n.ip_ts&&!n.online?" · 上次在线 "+ago(n.ip_ts):""}</dd>
<dt>入口</dt><dd>${esc(n.port)} · ${esc(n.sni)}</dd><dt>出口绑定</dt><dd>${esc(n.exit||"未绑定")}${n.shared?" ⚠ 共用":""}</dd></dl>
${(!n.online&&n.probe_err)?`<div class="err" style="font-size:13px">${esc(n.probe_err)}</div>`:""}
<div class="tr"><div><small>↑ 上传</small><b>${fb(n.up)}</b><small>${fb(n.rate_up)}/s</small></div><div><small>↓ 下载</small><b>${fb(n.down)}</b><small>${fb(n.rate_down)}/s</small></div></div>
<div class="barw" title="占全部节点最大值的比例"><div class="bar" style="width:${(n.total/mx*100).toFixed(1)}%"></div></div>
<div class="mut" style="font-size:12px">合计 ${fb(n.total)} · 自 ${ago(n.since)}</div>${spark(n.hist)}
<div class="nact">${d.manage?`<button class="btn s" data-a="link" data-n="${esc(n.name)}" type="button">查看链接 / 出口命令</button>`:""}
<button class="btn s" data-a="probe" data-n="${esc(n.name)}" type="button">探测</button>
<button class="btn s" data-a="reset" data-n="${esc(n.name)}" type="button">清零</button>
${d.manage?`<button class="btn s d" data-a="del" data-n="${esc(n.name)}" type="button">删除</button>`:""}</div></section>`}).join("")||'<div class="card empty mut">还没有节点</div>';
$("bAdd").hidden=!d.manage;$("bAdd").disabled=busy}
async function load(){try{const r=await fetch(P+"/api/status",{cache:"no-store"});if(r.status==401){location.href=P+"/";return}render(await r.json())}catch(e){toast("加载失败："+e.message,"bad")}}
function cp(t,b){(navigator.clipboard?navigator.clipboard.writeText(t):Promise.reject()).then(()=>toast("已复制","ok"),()=>{const a=document.createElement("textarea");a.value=t;document.body.appendChild(a);a.select();try{document.execCommand("copy");toast("已复制","ok")}catch(e){toast("复制失败，请手动选择","bad")}a.remove()})}
function showRes(j,title){$("dResH").textContent=title;$("resB").innerHTML=`<label>客户端分享链接（导入后核对 flow=xtls-rprx-vision）</label><div class="copy"><span class="mono" id="rL"></span><button class="btn s" type="button" id="cL">复制</button></div>
<label>到这个节点的出口机（B）上执行</label><div class="copy"><span class="mono" id="rC"></span><button class="btn s" type="button" id="cC">复制</button></div>
<p class="err" style="font-size:13px">链接和命令含密钥，只在自己设备间使用。</p>`;$("rL").textContent=j.link;$("rC").textContent=j.exit_cmd;
$("cL").onclick=()=>cp(j.link);$("cC").onclick=()=>cp(j.exit_cmd);$("dRes").showModal()}
document.querySelectorAll("[data-close]").forEach(b=>b.onclick=()=>b.closest("dialog").close());
$("list").addEventListener("click",async e=>{const b=e.target.closest("button[data-a]");if(!b)return;const a=b.dataset.a,n=b.dataset.n;
try{if(a=="link"){if(!confirm("显示节点 "+n+" 的分享链接和出口机命令？\\n含密钥，注意身边没人看屏幕。"))return;b.disabled=true;showRes(await post("/api/link",{node:n}),"节点 "+n)}
else if(a=="probe"){b.disabled=true;b.textContent="探测中…";await post("/api/probe",{node:n});toast("已探测 "+n,"ok");load()}
else if(a=="reset"){if(!confirm("把节点 "+n+" 的累计流量清零？"))return;await post("/api/reset",{node:n});toast("已清零","ok");load()}
else if(a=="del"){$("delN").textContent=n;$("delIn").value="";$("delGo").disabled=true;$("fDel").dataset.n=n;$("dDel").showModal();$("delIn").focus()}}
catch(x){fail(x.message,x.out)}finally{b.disabled=false}});
$("delIn").oninput=()=>{$("delGo").disabled=$("delIn").value!==$("fDel").dataset.n};
$("fDel").onsubmit=async ev=>{ev.preventDefault();const n=$("fDel").dataset.n;if($("delIn").value!==n)return;$("delGo").disabled=true;$("delGo").textContent="删除中…";
try{await post("/api/del",{node:n,confirm:$("delIn").value});$("dDel").close();toast("节点 "+n+" 已删除","ok")}catch(x){$("dDel").close();fail("删除失败："+x.message,x.out)}
finally{$("delGo").textContent="删除";load()}};
$("aSni").innerHTML='<option value="">沿用主入口</option>'+SNIS.map(s=>`<option value="${esc(s[0])}">${esc(s[0])}（${esc(s[1])}）</option>`).join("")+'<option value="__c">自定义…</option>';
$("aSni").onchange=()=>{$("aCustW").hidden=$("aSni").value!="__c"};
$("bAdd").onclick=()=>{const m=D&&D.nodes[0];$("defPort").textContent=m?m.port:"";$("defSni").textContent=m?m.sni:"";$("fAdd").reset();$("aCustW").hidden=true;$("dAdd").showModal();$("aName").focus()};
$("fAdd").onsubmit=async ev=>{ev.preventDefault();const name=$("aName").value.trim(),port=$("aPort").value.trim();let sni=$("aSni").value;if(sni=="__c")sni=$("aCust").value.trim();
if(!/^[A-Za-z0-9_-]{1,32}$/.test(name)){toast("节点名只能用字母/数字/下划线/连字符，最多 32 位","bad");return}
if(port&&!(/^[0-9]+$/.test(port)&&+port>=1&&+port<=65535)){toast("端口必须是 1-65535","bad");return}
if(sni&&!/^[A-Za-z0-9.-]+$/.test(sni)){toast("域名格式不对","bad");return}
$("aGo").disabled=true;$("aGo").textContent="添加中…（约 10 秒）";
try{const j=await post("/api/add",{name,port,sni});$("dAdd").close();toast("节点 "+name+" 已添加","ok");showRes(j,"新节点 "+name+" 已添加")}
catch(x){fail("添加失败："+x.message,x.out)}finally{$("aGo").disabled=false;$("aGo").textContent="添加";load()}};
$("bRef").onclick=load;
$("bProbe").onclick=async e=>{const b=e.target;b.disabled=true;b.textContent="探测中…";try{await post("/api/probe",{});toast("探测完成","ok")}catch(x){toast(x.message,"bad")}b.disabled=false;b.textContent="立即探测";load()};
load();setInterval(load,12000);
</script></body></html>'''


class H(http.server.BaseHTTPRequestHandler):
    server_version = 'att-web'
    sys_version = ''

    def log_message(self, fmt, *a):
        pass  # 不记访问日志（里面会有路径前缀）

    def send(self, code, body, ctype='text/html; charset=utf-8', extra=None):
        b = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(b)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy',
                         "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                         "img-src data:; connect-src 'self'; form-action 'self'; frame-ancestors 'none'")
        for k, v in (extra or []):
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(b)

    def jsend(self, code, obj):
        return self.send(code, json.dumps(obj, ensure_ascii=False), 'application/json; charset=utf-8')

    def redirect(self, to, extra=None):
        self.send(303, '', extra=[('Location', to)] + (extra or []))

    def session(self):
        c = http.cookies.SimpleCookie()
        try:
            c.load(self.headers.get('Cookie', ''))
        except Exception:
            return None, None
        m = c.get('att_sid')
        if not m:
            return None, None
        with lock:
            s = sessions.get(m.value)
            if not s or s['exp'] < time.time():
                return None, None
            return m.value, s

    def form(self):
        n = min(int(self.headers.get('Content-Length') or 0), 4096)
        raw = self.rfile.read(n).decode('utf-8', 'replace') if n else ''
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}

    def route(self):
        p = urllib.parse.urlsplit(self.path).path
        if p != PREFIX and not p.startswith(PREFIX + '/'):
            return None
        return p[len(PREFIX):] or '/'

    def login_page(self, code, msg=''):
        e = '<p class="err">%s</p>' % msg if msg else ''
        return self.send(code, PAGE_LOGIN.replace('{CSS}', CSS).replace('{P}', PREFIX).replace('{E}', e))

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        r = self.route()
        if r is None:
            return self.send(404, 'Not Found', 'text/plain')
        sid, s = self.session()
        if r == '/':
            if not s:
                return self.login_page(200)
            page = (PAGE_MAIN.replace('{CSS}', CSS).replace('{P}', PREFIX).replace('{C}', s['csrf'])
                    .replace('{SNIS}', json.dumps(SNI_PRESETS, ensure_ascii=False)))
            return self.send(200, page)
        if r == '/api/status':
            if not s:
                return self.jsend(401, {'error': 'unauthorized'})
            return self.jsend(200, status_json())
        return self.send(404, 'Not Found', 'text/plain')

    def do_POST(self):
        r = self.route()
        if r is None:
            return self.send(404, 'Not Found', 'text/plain')
        ip = self.client_address[0]
        if r == '/login':
            if rate_limited(ip):
                return self.login_page(429, '失败次数过多，请 10 分钟后再试')
            f = self.form()
            if hmac.compare_digest(f.get('password', '').encode(), PASS.encode()):
                sid = new_session()
                ck = ('att_sid=%s; Path=%s; HttpOnly; SameSite=Strict; Max-Age=%d'
                      % (sid, PREFIX, SESSION_TTL))
                return self.redirect(PREFIX + '/', [('Set-Cookie', ck)])
            note_fail(ip)
            time.sleep(1)
            return self.login_page(401, '密码错误')
        sid, s = self.session()
        if not s:
            return self.jsend(401, {'error': 'unauthorized'})
        f = self.form()
        tok = self.headers.get('X-CSRF-Token') or f.get('csrf', '')
        if not hmac.compare_digest(tok.encode(), s['csrf'].encode()):
            return self.jsend(403, {'error': 'CSRF 校验失败，请刷新页面'})
        if r == '/logout':
            with lock:
                sessions.pop(sid, None)
            ck = 'att_sid=; Path=%s; HttpOnly; SameSite=Strict; Max-Age=0' % PREFIX
            return self.redirect(PREFIX + '/', [('Set-Cookie', ck)])
        n = f.get('node', '')
        if r in ('/api/reset', '/api/link', '/api/del') and n not in node_names():
            return self.jsend(404, {'error': '节点 %s 不存在' % n})
        if r == '/api/reset':
            with lock:
                rec = node_rec(n)
                rec['up'] = rec['down'] = 0
                rec['hist'] = []
                rec['since'] = now()
            safe_save()
            return self.jsend(200, {'ok': True})
        if r == '/api/probe':
            probe_all(n or None)
            return self.jsend(200, {'ok': True})
        if r in ('/api/link', '/api/add', '/api/del') and not os.path.isfile(SCRIPT):
            return self.jsend(501, {'error': '面板未开启节点管理：请在 A 机重跑一次 --web'})
        if r == '/api/link':
            try:
                return self.jsend(200, dict(node_link(n), ok=True))
            except Exception as e:
                return self.jsend(500, {'error': '取链接失败', 'output': str(e)})
        if r == '/api/add':
            return self.do_add(f)
        if r == '/api/del':
            if f.get('confirm') != n:
                return self.jsend(400, {'error': '确认名称不一致'})
            if not mut_lock.acquire(blocking=False):
                return self.jsend(409, {'error': '另一个加/删操作正在进行，请稍后'})
            try:
                rc, out = run_script(['--del', n], {'ATT_YES': '1'})
                after_change()
            finally:
                mut_lock.release()
            if rc != 0:
                return self.jsend(500, {'error': '脚本返回 %d（配置未改动或已回滚）' % rc, 'output': out})
            return self.jsend(200, {'ok': True, 'output': out})
        return self.send(404, 'Not Found', 'text/plain')

    def do_add(self, f):
        name, port, sni = f.get('name', '').strip(), f.get('port', '').strip(), f.get('sni', '').strip()
        if not NAME_RE.match(name):
            return self.jsend(400, {'error': '节点名只能用字母/数字/下划线/连字符，最多 32 位'})
        if port and not (port.isdigit() and 1 <= int(port) <= 65535):
            return self.jsend(400, {'error': '端口必须是 1-65535'})
        if sni and not SNI_RE.match(sni):
            return self.jsend(400, {'error': '伪装域名格式不对'})
        if name in node_names():
            return self.jsend(409, {'error': '节点 %s 已存在' % name})
        if not mut_lock.acquire(blocking=False):
            return self.jsend(409, {'error': '另一个加/删操作正在进行，请稍后'})
        try:
            env = {'ATT_NODE_PORT': port, 'ATT_NODE_SNI': sni}
            rc, out = run_script(['--add', name], env, timeout=240)
            after_change(name)
        finally:
            mut_lock.release()
        if rc != 0:
            return self.jsend(500, {'error': '脚本返回 %d（配置未改动或已回滚）' % rc, 'output': out})
        try:
            return self.jsend(200, dict(node_link(name), ok=True, output=out))
        except Exception as e:
            return self.jsend(200, {'ok': True, 'output': out, 'link': '（取链接失败：%s）' % e,
                                    'exit_cmd': ''})


class Srv(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    load_state()
    state['started'] = now()
    log('att-tunnel 面板 v%s 启动，监听 %s:%d' % (VERSION, LISTEN, PORT))
    threading.Thread(target=worker, daemon=True).start()
    Srv((LISTEN, PORT), H).serve_forever()


if __name__ == '__main__':
    main()
ATT_WEB_PY
  sed -i "s/ATT_VERSION/$VERSION/g" "$WEB_PY.tmp"
  # 伪装域名预置列表和脚本同源（面板「添加节点」下拉框用）
  ATT_SNIS="$(printf '%s\n' "${CANDIDATES_WITH_COUNTRY[@]}")" python3 - "$WEB_PY.tmp" <<'PY' || { rm -f "$WEB_PY.tmp"; die "面板程序生成失败"; }
import json,os,sys
f=sys.argv[1]; s=open(f).read()
l=[x.split('|',1) for x in os.environ['ATT_SNIS'].splitlines() if '|' in x]
open(f,'w').write(s.replace('"ATT_SNI_PRESETS"', json.dumps(l, ensure_ascii=False), 1))
PY
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$WEB_PY.tmp" 2>/dev/null || { rm -f "$WEB_PY.tmp"; die "面板程序生成失败（python3 语法检查不通过）"; }
  chmod 700 "$WEB_PY.tmp"; mv "$WEB_PY.tmp" "$WEB_PY"
}

web_url(){
  # shellcheck disable=SC1090,SC1091
  source "$STATE/a.env"
  # shellcheck disable=SC1090,SC1091
  source "$WEB_ENV"
  echo "http://$A_IP:$WEB_PORT/$WEB_PATH/"
}

# 面板加/删节点调用的是本机脚本副本（同一套配置逻辑、校验和回滚，不在面板里重写）。
# 本地文件运行：直接复制自己；bash <(curl ...) 运行（\$0 是管道读不回来）：按 RAW_URL 重新下载，
# 并核对版本号一致，防止拉到别的分支。
install_script_copy(){
  mkdir -p "$WEB_DIR"
  local tmp; tmp=$(mktemp)
  if [ -f "$0" ] && [ -r "$0" ] && grep -q '^VERSION="'"$VERSION"'"' "$0" 2>/dev/null; then
    cp "$0" "$tmp"
  elif ! curl -fsSL --max-time 60 -o "$tmp" "$RAW_URL"; then
    rm -f "$tmp"; warn "下载脚本副本失败（$RAW_URL），面板暂不能加/删节点"; return 1
  fi
  if ! grep -q '^VERSION="'"$VERSION"'"' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    warn "脚本副本版本与当前不一致（$RAW_URL 不是 v$VERSION），面板暂不能加/删节点"
    warn "用 ATT_RAW_URL 指向本版本的 install.sh 再跑一次 --web"
    return 1
  fi
  install -m 700 -o root -g root "$tmp" "$WEB_SCRIPT"; rm -f "$tmp"
  ok "脚本副本已更新：$WEB_SCRIPT（v$VERSION）"
}

# 把本次用的脚本地址记进 web.env，面板生成的出口机命令指向同一版本
save_web_raw_url(){
  [ -f "$WEB_ENV" ] || return 0
  sed -i '/^WEB_RAW_URL=/d' "$WEB_ENV"
  printf 'WEB_RAW_URL=%s\n' "$RAW_URL" >> "$WEB_ENV"
}

web_enable(){
  need_root
  [ -f "$STATE/a.env" ] || die "网页面板只在 A 端（入口机）上用"
  command -v python3 >/dev/null || die "缺 python3"
  command -v flock >/dev/null || die "缺 flock（util-linux）"
  stats_enabled || enable_stats
  stats_enabled || die "统计未启用，无法开面板"
  if [ ! -f "$WEB_ENV" ]; then
    local p; p=$(free_port)
    umask 077
    printf 'WEB_PORT=%s\nWEB_PATH=%s\nWEB_PASS=%s\nWEB_LISTEN=0.0.0.0\n' \
      "$p" "$(openssl rand -hex 8)" "$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-16)" > "$WEB_ENV"
    umask 022
  fi
  chmod 600 "$WEB_ENV"; chown root:root "$WEB_ENV"
  write_web_py
  install_script_copy || true
  save_web_raw_url
  mkdir -p "$WEB_DATA"; chmod 700 "$WEB_DATA"
  cat > "/etc/systemd/system/$WEB_SVC.service" <<EOF
[Unit]
Description=att-tunnel 流量面板
After=network-online.target $SVC.service

[Service]
Type=simple
Environment=ATT_CFG=$CFG ATT_WEB_ENV=$WEB_ENV ATT_WEB_STATE=$WEB_DATA/web-state.json ATT_XRAY=$XRAY_BIN
Environment=ATT_SCRIPT=$WEB_SCRIPT ATT_A_ENV=$STATE/a.env ATT_SVC=$SVC
ExecStart=$(command -v python3) $WEB_PY
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$WEB_SVC" >/dev/null 2>&1 || true
  systemctl restart "$WEB_SVC"
  sleep 2
  systemctl is-active --quiet "$WEB_SVC" || {
    journalctl -u "$WEB_SVC" -n 15 --no-pager 2>&1 | tail -10
    die "面板启动失败"; }
  # shellcheck disable=SC1090
  source "$WEB_ENV"
  open_fw "$WEB_PORT"
  ok "网页面板已启用"
  web_info
}

web_disable(){
  need_root
  systemctl stop "$WEB_SVC" 2>/dev/null || true
  systemctl disable "$WEB_SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$WEB_SVC.service"
  systemctl daemon-reload 2>/dev/null || true
  ok "网页面板已关闭（累计流量数据保留在 $WEB_DATA，重新开启后继续累计）"
}

web_info(){
  [ -f "$WEB_ENV" ] || { warn "网页面板还没启用（菜单 13）"; return 1; }
  # shellcheck disable=SC1090
  source "$WEB_ENV"
  if systemctl is-active --quiet "$WEB_SVC" 2>/dev/null; then ok "面板运行中"; else warn "面板当前未运行"; fi
  echo "  地址：${GRN}$(web_url)${RST}"
  echo "  密码：${GRN}$WEB_PASS${RST}"
  echo "  ${YEL}面板是明文 HTTP，靠随机路径 + 密码保护；别在不可信网络里登录，地址和密码不要外发${RST}"
  warn "云厂商安全组需放行 $WEB_PORT/tcp 才能从外面打开"
}

web_menu(){
  [ -f "$STATE/a.env" ] && install_script_copy || true
  if systemctl is-active --quiet "$WEB_SVC" 2>/dev/null; then
    read -rp "面板运行中，关闭它？（输 yes）: " c
    [ "$c" = yes ] && web_disable || warn "未改动"
  else
    web_enable
  fi
}

# ================= 自检 =================
selfcheck(){
  echo "${BLD}--- 运行自检 ---${RST}"
  if systemctl is-active --quiet "$SVC"; then ok "$SVC active"; else echo "${RED}[X]${RST} $SVC 未运行"; fi
  if [ -x /usr/local/bin/xray ]; then
    local xv; xv=$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print $2}')
    if [ "$xv" = "${XRAY_VER#v}" ]; then
      ok "专用 Xray 版本 $xv（两端必须一致）"
    else
      warn "专用 Xray 版本 $xv，期望 ${XRAY_VER#v} —— 重跑脚本会自动换成期望版本"
    fi
  fi

  if [ -f "$STATE/a.env" ]; then
    source "$STATE/a.env"
    echo "角色: ${BLD}A（入口端）${RST}   本机 IP: $A_IP   入口端口: ${USER_PORT:-443}   反代端口: $REVERSE_PORT"
    ss -ltn 2>/dev/null | grep -q ":${USER_PORT:-443} " && ok "入口端口 ${USER_PORT:-443} 监听中" || echo "${RED}[X]${RST} 入口端口 ${USER_PORT:-443} 未监听"
    ss -ltn 2>/dev/null | grep -q ":$REVERSE_PORT " && ok "反代口 $REVERSE_PORT 监听中" || echo "${RED}[X]${RST} 反代口未监听"

    # 节点 / 出口机 对应表（严格 1:1）
    if needs_migrate; then
      echo
      warn "配置还是旧的单出口结构（所有节点共一台 B）"
      warn "跑菜单 9 可以直接平滑升级（加/删节点时也会自动升），或跑：$0 --migrate"
    fi
    local rows nexit=0
    rows=$(list_exits 2>/dev/null || true)
    if [ -n "$rows" ]; then
      echo
      echo "${BLD}节点 / 出口机（1:1）${RST}"
      local n p u
      while IFS=$'\t' read -r n p u; do
        [ -z "$n" ] && continue
        if [ -z "$p" ]; then
          echo "    $n  ${RED}未绑定出口机→流量从 A 出网，泄露 A 的 IP${RST}"
        else
          echo "    $n  →  $p"
          nexit=$((nexit+1))
        fi
      done <<< "$rows"
    fi

    # 配置自检：xray -test 拦不住的错配（泄露 A IP / 标签重复 / 悬空引用）
    local vmsg
    if vmsg=$(validate_cfg "$CFG" 2>/dev/null); then
      ok "节点与出口绑定自检通过"
    else
      echo "${RED}[X]${RST} 配置自检发现问题："
      echo "$vmsg" | sed 's/^/    /'
    fi

    # 多出口下多条隧道是正常的，只有超出出口数才可疑（僵死连接）
    local ntun; ntun=$(ss -tn state established 2>/dev/null | grep -c ":$REVERSE_PORT")
    if [ "$ntun" = 0 ]; then
      warn "没有来自 B 的 ESTAB —— 出口机未部署或端口被封"
    else
      ok "反向隧道连接数：$ntun（已绑定出口：$nexit）"
      ss -tn state established 2>/dev/null | grep ":$REVERSE_PORT" | sed -n 1,5p | sed 's/^/    /'
      if [ "$nexit" -gt 0 ] && [ "$ntun" -lt "$nexit" ]; then
        warn "隧道数少于出口数 —— 有出口机没连上（未部署 / 安全组未放行 / 已关机）"
      fi
      if [ "$nexit" -gt 0 ] && [ "$ntun" -gt "$nexit" ]; then
        warn "隧道数多于出口数 —— 可能有僵死连接（某台 B 刚换过 IP）"
        warn "部分请求会挂死，等 ~20s 内核回收；若长期如此查：sysctl net.ipv4.tcp_retries2（应为 5）"
      fi
    fi
    local r2; r2=$(sysctl -n net.ipv4.tcp_retries2 2>/dev/null)
    [ "$r2" = 5 ] && ok "tcp_retries2=5（僵死隧道快速回收）" || warn "tcp_retries2=$r2，建议为 5"
    echo; info "逐个节点验收：连上后查出口 IP，必须等于${BLD}它对应那台出口机的实时公网 IP${RST}"
    info "如果显示的是 A 的 IP（$A_IP），说明该节点的流量没进 portal"
    info "如果两个节点查出同一个出口 IP，说明它们共用了出口，不是 1:1"
  elif [ -f "$STATE/b.env" ]; then
    source "$STATE/b.env"
    echo "角色: ${BLD}B（出口端）${RST}   拨向: $A_IP:$REVERSE_PORT"
    if ss -tn state established 2>/dev/null | grep -q "$A_IP:$REVERSE_PORT"; then
      ok "隧道 ESTAB 正常"
    else
      echo "${RED}[X]${RST} 隧道未建立，检查 A 侧防火墙/安全组 $REVERSE_PORT/tcp"
    fi
    local listen; listen=$(ss -ltn 2>/dev/null | grep -vE '127.0.0.1|::1|State' | wc -l)
    ok "对外监听端口数（含 SSH）: $listen"
    grep -q '"inbounds": \[\]' "$CFG" && ok "B 无任何用户入站（零暴露）" || warn "B 端出现了 inbound，与设计不符"
    echo -n "本机实时公网 IP: "; pubip; echo
  else
    warn "未找到部署状态，尚未部署"
  fi
  echo
}

# ================= SSH 端口迁移（危险操作，单独菜单） =================
ssh_migrate(){
  need_root
  echo "${YEL}${BLD}⚠ 这个操作会修改 SSH 端口，操作不当会把你自己锁在外面。${RST}"
  echo "流程：新旧端口先并存 → 你新开一个会话实测新端口 → 确认后手动收揉 22"
  echo "${BLD}全程不要关掉你当前这个 SSH 会话。${RST}"
  echo
  read -rp "新端口（20000-60000，回车随机）: " np
  [ -n "$np" ] || np=$(free_port)
  case "$np" in (*[!0-9]*) die "端口必须是数字";; esac
  [ "$np" -ge 1024 ] && [ "$np" -le 65535 ] || die "端口越界"
  read -rp "确认把 SSH 加监听到 $np？输 yes 继续: " c
  [ "$c" = yes ] || { warn "已取消"; return; }

  open_fw "$np"
  mkdir -p /etc/ssh/sshd_config.d
  printf 'Port 22\nPort %s\n' "$np" > /etc/ssh/sshd_config.d/00-att-tunnel-port.conf
  sshd -t || { rm -f /etc/ssh/sshd_config.d/00-att-tunnel-port.conf; die "sshd 配置校验失败，已回滚"; }
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  sleep 1
  ss -ltn | grep -q ":$np " && ok "新端口 $np 已监听（22 仍在）" || die "新端口未监听"
  echo
  echo "${BLD}现在另开一个终端实测：${RST} ssh -p $np root@\$(本机IP)"
  echo "确认能登录后，再跑下面两行收揉 22："
  echo "${CYN}  printf 'Port $np\\n' > /etc/ssh/sshd_config.d/00-att-tunnel-port.conf${RST}"
  echo "${CYN}  sshd -t && systemctl restart ssh${RST}"
  echo "然后在云安全组回收 22/tcp，并：ufw delete allow 22/tcp"
  warn "我不会自动删 22 —— 必须你亲自验证新端口可登录之后再做。"
}

# ================= 卸载 =================
uninstall(){
  need_root
  read -rp "确认卸载 att-tunnel？（不影响你其他 xray 节点，输 yes）: " c
  [ "$c" = yes ] || { warn "已取消"; return; }
  systemctl stop "$WEB_SVC" 2>/dev/null || true
  systemctl disable "$WEB_SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$WEB_SVC.service"
  systemctl stop "$SVC" 2>/dev/null || true
  systemctl disable "$SVC" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SVC.service"
  systemctl daemon-reload 2>/dev/null || true
  local bdir="/root/att-tunnel-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$bdir"
  [ -f "$CFG" ] && cp "$CFG" "$bdir/" 2>/dev/null || true
  [ -d "$STATE" ] && cp -r "$STATE" "$bdir/" 2>/dev/null || true
  [ -d "$WEB_DATA" ] && cp -r "$WEB_DATA" "$bdir/" 2>/dev/null || true
  rm -rf "$STATE" "$CFG_DIR" "$WEB_DIR" "$WEB_DATA"
  ok "已停止并清理 att-tunnel。备份在：$bdir"
  ok "你机器上原有的 xray / 3x-ui / NodeLite 未受影响"
  warn "Xray 二进制未删除（可能其他服务在用）"
  warn "SSH 端口改动不会自动还原，需手动处理 /etc/ssh/sshd_config.d/00-att-tunnel-port.conf"
}

# ================= 菜单 =================
menu(){
  while :; do
    echo
    echo "${BLD}  att-tunnel v$VERSION${RST}  — AT&T 丢包反向隧道"
    echo "  ──────────────────────────────"
    echo "  1) 部署服务器 A（境外入口机）"
    echo "  2) 部署服务器 B（AT&T 出口机，需 A 的 token）"
    echo "  3) 看节点分享链接"
    echo "  4) 节点 / 出口机 对应表"
    echo "  5) 加一个节点（同时生成它专属出口机的部署命令）"
    echo "  6) 重新拿某节点的出口机部署命令"
    echo "  7) 删除一个节点（连带它的出口绑定）"
    echo "  8) 运行自检"
    echo "  9) 升级配置为 1:1 多出口结构（平滑，客户端不变）"
    echo " 10) SSH 搬到高位端口（可选，小心）"
    echo " 11) 卸载"
    echo " 12) 启用流量统计 / 出口探测（老 A 机升级，幂等）"
    echo " 13) 网页流量面板：开启 / 关闭"
    echo " 14) 查看网页面板地址和密码"
    echo "  0) 退出"
    echo
    read -rp "选择: " ch
    case "$ch" in
      1) deploy_a ;;
      2) read -rp "粘贴 A 端给的 token: " t; deploy_b "$t" ;;
      3) show_links ;;
      4) show_exits ;;
      5) add_node ;;
      6) show_exit_cmd ;;
      7) del_node ;;
      8) selfcheck ;;
      9) migrate_menu ;;
      10) ssh_migrate ;;
      11) uninstall ;;
      12) enable_stats ;;
      13) web_menu ;;
      14) web_info ;;
      0) exit 0 ;;
      *) warn "无效选择" ;;
    esac
  done
}

# 生成给 B 的命令用哪个脚本地址；测试分支/指定提交时用 ATT_RAW_URL 覆盖
RAW_URL="${ATT_RAW_URL:-https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh}"

case "${1:-}" in
  --bridge)   need_root; deploy_b "${2:-}" ;;
  --server-a) deploy_a ;;
  --check)    selfcheck ;;
  --links)    show_links ;;
  --add)      add_node "${2:-}" ;;
  --del|--delete|--remove) del_node "${2:-}" ;;
  --list)     show_exits ;;
  --exit-cmd) show_exit_cmd "${2:-}" ;;
  --link)     [ -n "${2:-}" ] || die "用法：--link NAME"; show_links "$2" ;;
  --migrate)  migrate_cfg ;;
  --enable-stats) enable_stats ;;
  --web)      web_enable ;;
  --web-off)  web_disable ;;
  --web-info) web_info ;;
  --version)  echo "att-tunnel v$VERSION" ;;
  "")         menu ;;
  *)          die "未知参数: $1（可用：--server-a | --bridge TOKEN | --check | --links | --list | --add NAME | --del NAME | --exit-cmd NAME | --link NAME | --migrate | --enable-stats | --web | --web-off | --web-info）" ;;
esac
