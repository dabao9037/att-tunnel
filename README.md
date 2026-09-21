# att-tunnel

AT&T 家宽/商宽线路丢包根治：Xray VLESS Reverse 反向隧道一键部署。

**不绑域名**，B 端直连 A 的公网 IP；**B 换 IP 全自动重连**，无需改任何配置。

## 为什么有用

AT&T 的 BGW 网关固件里写死了一个上限：**每秒约 50 个新建入站连接**（突发 100），超出直接随机丢弃。这份预算是整条线路上所有 VM 共享的。

传统链式中转是「中转机主动连住宅机」，用户的并发全都变成打向住宅机的**入站**新连接，瞬间打爆预算 —— 表现就是 ping 通、老连接不断，但新连接随机失败。

反向隧道把方向反过来：

```
用户 ──> A（境外入口, 443）  <══ 反向隧道 ══  B（AT&T 出口） ──> Internet
                                B 主动外拨，零入站
```

- 用户的所有并发落在 **A**（境外线路，没这个限制）
- **B → A 只有一条连接**，且是 B 主动外拨的出站连接，长期保持
- B 代表用户出网，也是出站方向

B 侧的入站新连接数≈0，那份被打爆的预算不再被消耗。这不是调参，是把最吃预算的流量整个搬离受限线路。

顺带两个好处：B 换 IP 不用改配置；B 对外零暴露（不监听任何端口）。

## 用法

需要两台机器。**先 A 后 B。**

### 1. 服务器 A（境外稳定公网入口）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh)
```

选菜单 `1`。跑完会打印一行给 B 用的命令，直接复制。

要求：443 未被占用、公网 IP 固定（不绑域名的代价就是 A 的 IP 不能变）。

**端口自动降级：`443` → `8443` → 随机高位端口。** 443 空闲就用 443；被占就用 8443；8443 也被占就选一个随机高位端口。全程**不会动你已有的服务**。想自己指定：

```bash
ATT_PORT=8443 bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh) --server-a
```

注意：非 443 的 REALITY 伪装效果会打折（Xray 自己也会告警）。能腾出 443 就腾。

## 只生成一条链接（Vision）

每个节点只生成一条分享链接，**必带 `flow=xtls-rprx-vision`**，一切以抗封为准。

客户端导入后请核对 `flow` 字段在不在。`flow` 必须**两端完全一致**，客户端丢了这个参数就会报 `EOF` / `502`，服务端日志会写：

```
account ... is rejected since the client flow is empty
```

## 抗封说明

默认配置是 **VLESS + REALITY + XTLS Vision over TCP**，这是 REALITY 设计时的主用场景，也是目前社区最主流的抗封组合：

- **REALITY**：没有自签证书、不需域名。对外展示的是真实站点（默认 `www.atlasobscura.com`）的**真证书**；被主动探测时流量直接回落到该真站，探测者看不出异常。
  实测：从外部 `openssl s_client` 直连 A:443，得到 `subject=CN = atlasobscura.com`、`issuer=Google Trust Services`、`Verify return code: 0 (ok)`。
- **XTLS Vision**（`flow=xtls-rprx-vision`）：消除 TLS-in-TLS 指纹。没有它的话，TCP+REALITY 的内层 TLS 握手会在外层 TLS 里形成可识别特征。这是抗封的关键项。
- **端口建议用 443**。非 443 的 TLS 流量本身就显眼，Xray 自己也会对此告警。

关于传输方式：有人认为 XHTTP 伪装更好（看起来像 HTTP/2 访问），但它**不能与 Vision 共用**，而且 Clash/Mihomo 系客户端支持不完整。权衷之下默认选 **RAW + Vision**：兼容所有客户端，且指纹特征更小。

剩下的风险不在协议层：**回落域名要选你所在网络真实访问得通、且流量量级合理的站**（默认那批均已实测 REALITY 握手可用）；以及不要把节点做成公开代理。

**传输方式默认 RAW（`type=tcp`）**，所有客户端都支持。

> 之前默认 XHTTP，客户端不支持或未正确配置时会报
> `unexpected response version. Expecting 0 but actually 72`
> （72 = 字符 `H`，即 VLESS 层收到明文 HTTP）。
> 常见于 Clash / Mihomo 系客户端（它们用 `cp.cloudflare.com` 做健康检查，所以错误里常带这个地址）。

想用 XHTTP（伪装更好，但客户端必须支持）：

```bash
ATT_TRANSPORT=xhttp bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh) --server-a
```

**Xray 版本强制 v26.6.27**（26.7 及以后的版本有 bug）。本工具只用自己那份 `/usr/local/bin/xray`，**不复用机器上其他版本**；发现版本不对会自动卸载重装。

> A/B 两端 Xray 版本必须一致。不一致时客户端会报
> `unknown version: 72`（72 = 字符 `H`，即收到明文 HTTP 而不是 VLESS）。

需要换版本（两端都要改）：

```bash
ATT_XRAY_VER=v26.6.22 bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh) --server-a
```

**与现有节点完全隔离。** 本工具用独立配置 `/usr/local/etc/att-tunnel/config.json` 和独立服务 `att-tunnel.service`，**不覆盖 `/usr/local/etc/xray/config.json`，也不重启你的 `xray.service`**。机器上已有 3x-ui / NodeLite / 手动节点都能并存。卸载也只动自己的东西。

**已装过 Xray？** 脚本会直接复用（不重装），并自动探测版本是否支持 Reverse + XHTTP；不支持才询问你是否升级。除 `/usr/local/bin/xray` 外，也会自动在 `/usr/bin`、3x-ui、宝塔等常见路径查找。

**伪装域名（SNI）** 默认用 `www.atlasobscura.com`，与 NodeLite 保持一致。预置列表也和 NodeLite 同步，部署时会自动挑选当下真实可用的一个。想指定其他域名：

```bash
ATT_SNI=www.gog.com bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh) --server-a
```

（指定的域名不支持 TLS 1.3 时会告警并自动回退到预置列表）

### 2. 服务器 B（AT&T 出口机）

把 A 输出的那行原样粘过去执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh) --bridge <TOKEN>
```

token 里含隧道密钥，只在你自己两台机器间使用，不要外发。

### 3. 导入客户端

A 端菜单 `3` 看分享链接，任意支持 VLESS + REALITY + XHTTP 的客户端导入即可。

### 其他菜单

| 项 | 作用 |
|---|---|
| 3 | 看节点分享链接 |
| 4 | 加一个节点（复用同一条隧道） |
| 5 | 运行自检 |
| 6 | SSH 迁到高位端口（可选，需你自己确认新端口能登录后才收 22） |
| 7 | 卸载（配置自动备份到 /root/att-tunnel-backup-*） |

命令行等价：`--server-a` / `--bridge TOKEN` / `--links` / `--add NAME` / `--check`

## 验收判据

客户端连上后查出口 IP，**必须等于 B 的实时公网 IP**。如果显示 A 的 IP，说明路由没把用户流量送进 portal。

## 实现上踩过的坑

这些都是实测踩出来的，不是照抄文档：

1. **`www.microsoft.com` 作 REALITY 回落域名会握手失败**（Xray 26.3.27 实测：AuthKey 双方匹配，但 TLS 在 Certificate 阶段中断）。现在预置列表与 NodeLite 保持一致，并在部署时**实测挑选**。

   顺便对 NodeLite 的 12 个预置域名逐个做了真实 REALITY 握手测试，**11 个通过，`www.hkstp.org` 不通**（它 TLS 1.3 正常，但 REALITY 握手失败），故本脚本不纳入。

2. **A 侧不能手写 `portal` 出站**。reverse 组件会自己注册 handler，手写会报 `"vnext" should have one and only one member`。

3. **配置文件必须 644**。官方 service 以 `nobody` 运行，从 `/tmp` mv 过来的 600 权限会导致 `permission denied` 启动失败。

4. **`xray -test` 按扩展名判断格式**，`mktemp` 不带后缀会报 `Failed to get format`。

5. **B 换 IP 后 A 侧会留一条僵死隧道**，portal 仍往里派流量，导致约 1/4 请求挂死。`tcpUserTimeout` 对 accept 出来的连接不生效；真正有效的是内核 `tcp_retries2`（默认 15 ≈ 15 分钟）。脚本设为 5（≈20 秒）。实测：调之前 6/8，调之后 10/10。

7. **新版 Xray（26.4+）已移除旧 `reverse` 语法**。旧写法（顶层 `reverse.portals/bridges` + 虚拟域名路由）会直接报 `The feature "legacy reverse" has been removed`。新写法是在 VLESS user 上写 `"reverse": {"tag": "portal"}`，B 侧 outbound 必须用 simplified style（`address`/`port`/`id` 平铺，不能用 `vnext`）。脚本会自动探测用哪一代并生成对应配置。

8. **新版 freedom 对 `vless-reverse` 入站默认 block 全部流量**（源码 `getDefaultFinalRule` 里的反滥用设计）。表现是隧道 ESTAB 正常、路由也对，但流量全被 `blocked target ... blackholing` 。必须在 B 的 freedom 上显式写 `finalRules`（先 block `geoip:private` 再 `allow`）。

9. **不能用官方安装脚本升级别人的 Xray**。它会 stop/接管 `xray.service`（在只有面板自建服务的机器上直接报 `Unit xray.service not loaded` 并失败），而且它装的版本可能比你现有的**更旧**（实例：NodeLite 自带 26.6.27，官方脚本却装 26.3.27，属于降级）。现在改为直接拉 latest 二进制，并且**绝不覆盖非 `/usr/local/bin/xray` 的二进制**；若现有的太旧，另装一份到 `/usr/local/bin/xray` 专用。

6. **已装 Xray 的机器上原本会误报「安装 Xray 失败」**。原因有两层：安装输出被丢进 `/dev/null` 所以真实错误不可见；以及已有 xray 占着 443 时报错没说清怎么办。现在改为复用已有 xray + 打印官方脚本真实错误 + 列出 443 占用进程并给出解决办法。

## 已验证

在两台全新 Debian 12 容器上从零部署，Xray 26.3.27：

- A/B 双端部署成功，隧道 ESTAB 建立
- 真实客户端经 A(443 REALITY+XHTTP) → 反向隧道 → B 出网，**连续 12/12 次 HTTP 200**
- A 日志确认 `[user-in -> portal] email: node1`（用户流量确实走反向隧道）
- B 侧 `inbounds: []`，无任何用户入站监听
- 加节点后原节点不受影响（6/6）
- A 重启后 B 30 秒内自动重拨恢复
- B 换 IP 后自动重连（8/10，前 2 次是重拨窗口）
- 已装 Xray 的机器：复用现有 xray、正确探测 Reverse+XHTTP 支持、443 被占时给出可操作提示
- `ATT_PORT=8443` 自定义入口端口：端到端 10/10，分享链接与自检均正确显示 8443
- 默认 443 路径回归测试 10/10（无退化）
- SNI 换为 NodeLite 的 `www.atlasobscura.com` 后端到端 12/12；`ATT_SNI` 手动指定与无效域名自动回退均正常
- **与现有 xray 节点共存验证**：在一台已跑着 REALITY 节点（占着 443）的机器上安装 —— 安装前后对方配置 SHA256 / 服务状态 / MainPID 完全一致，原节点流量 6/6；新节点自动落到 8443 并 12/12；两节点同时可用各 5/5；卸载 att-tunnel 后原节点仍 6/6
- **新语法（VLESS Reverse Proxy）端到端 12/12**，包含 freedom finalRules 放行修正
- **NodeLite 场景验证**：机器上只有 `/opt/nodelite/bin/xray`（旧版）时，脚本另装一份新版到 `/usr/local/bin/xray` 专用，NodeLite 二进制 SHA256 前后完全一致，新节点 12/12

**未验证**：真实 AT&T 线路上的丢包改善幅度（需要实际 AT&T 出口机）；不同云厂商安全组需自行放行 443 与反代端口。

## 注意

- 只在你自己的两台机器之间用。把住宅出口做成公开代理，IP 会很快被扫进公开代理库，价值不可逆损失。
- REALITY 私钥、VLESS Encryption 材料只留在服务器上，不外发不截图。
- 非空白环境先停手：如果 A 或 B 上已有服务占用 443 或反代端口，脚本会报错退出，不会覆盖未知服务。
- 仅限合法合规且获得授权的用途，遵守当地法律与服务商条款。

## License

MIT
