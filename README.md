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

**443 已被占用？**（机器上已有 xray / nginx / 3x-ui）脚本会列出占用进程并停下，不动你现有服务。两个办法：

```bash
# 办法一：换个入口端口
ATT_PORT=8443 bash <(curl -fsSL https://raw.githubusercontent.com/dabao9037/att-tunnel/main/install.sh) --server-a

# 办法二：先停掉占 443 的服务再重跑
```

**已装过 Xray？** 脚本会直接复用（不重装），并自动探测版本是否支持 Reverse + XHTTP；不支持才询问你是否升级。除 `/usr/local/bin/xray` 外，也会自动在 `/usr/bin`、3x-ui、宝塔等常见路径查找。

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

1. **`www.microsoft.com` 作 REALITY 回落域名会握手失败**（Xray 26.3.27 实测：AuthKey 双方匹配，但 TLS 在 Certificate 阶段中断）。脚本改为从 apple / cloudflare / icloud / dl.google / bing 里**实测挑选**可用的。

2. **A 侧不能手写 `portal` 出站**。reverse 组件会自己注册 handler，手写会报 `"vnext" should have one and only one member`。

3. **配置文件必须 644**。官方 service 以 `nobody` 运行，从 `/tmp` mv 过来的 600 权限会导致 `permission denied` 启动失败。

4. **`xray -test` 按扩展名判断格式**，`mktemp` 不带后缀会报 `Failed to get format`。

5. **B 换 IP 后 A 侧会留一条僵死隧道**，portal 仍往里派流量，导致约 1/4 请求挂死。`tcpUserTimeout` 对 accept 出来的连接不生效；真正有效的是内核 `tcp_retries2`（默认 15 ≈ 15 分钟）。脚本设为 5（≈20 秒）。实测：调之前 6/8，调之后 10/10。

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

**未验证**：真实 AT&T 线路上的丢包改善幅度（需要实际 AT&T 出口机）；不同云厂商安全组需自行放行 443 与反代端口。

## 注意

- 只在你自己的两台机器之间用。把住宅出口做成公开代理，IP 会很快被扫进公开代理库，价值不可逆损失。
- REALITY 私钥、VLESS Encryption 材料只留在服务器上，不外发不截图。
- 非空白环境先停手：如果 A 或 B 上已有服务占用 443 或反代端口，脚本会报错退出，不会覆盖未知服务。
- 仅限合法合规且获得授权的用途，遵守当地法律与服务商条款。

## License

MIT
