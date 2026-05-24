# 功能矩阵

## 规则类型总览

| 菜单路径 | 内部类型 | `rawconf` 格式 | 渲染结果 |
| --- | --- | --- | --- |
| `7 -> 1` 不加密转发 | `nonencrypt` | `nonencrypt/<listen>#<host>#<port>` | `tcp+udp` 直连转发 |
| `7 -> 2 -> 1` tls 中转 | `encrypttls` | `encrypttls/<listen>#<host>#<port>` | `tcp+udp` + `relay+tls` chain |
| `7 -> 2 -> 2` ws 中转 | `encryptws` | `encryptws/<listen>#<host>#<port>` | `tcp+udp` + `relay+ws` chain |
| `7 -> 2 -> 3` wss 中转 | `encryptwss` | `encryptwss/<listen>#<host>#<port>` | `tcp+udp` + `relay+wss` chain |
| `7 -> 3 -> 1` tls 解密 | `decrypttls` | `decrypttls/<listen>#<host>#<port>` | `relay+tls` 落地监听 |
| `7 -> 3 -> 2` ws 解密 | `decryptws` | `decryptws/<listen>#<host>#<port>` | `relay+ws` 落地监听 |
| `7 -> 3 -> 3` wss 解密 | `decryptwss` | `decryptwss/<listen>#<host>#<port>` | `relay+wss` 落地监听 |
| `7 -> 4 -> 1` shadowsocks | `ss` | `ss/<password>#<cipher>#<port>` | `ss://` 代理 |
| `7 -> 4 -> 2` socks5 | `socks` | `socks/<password>#<username>#<port>` 或 `socks/#__NOAUTH__#<port>` | `socks5://` 代理 |
| `7 -> 4 -> 3` http | `http` | `http/<password>#<username>#<port>` 或 `http/#__NOAUTH__#<port>` | `http://` 代理 |
| `7 -> 4 -> 4` https | `https` | `https/<listen>#<bind>#<auth_mode>\|<username>\|<password>\|<cert>\|<key>\|<kind>` | `https://` 代理，`listener: tls` |
| `7 -> 5 -> 1` 不加密均衡 | `peerno` | `peerno/<listen>#<list_name>#<strategy>` | `forwarder.nodes + selector` |
| `7 -> 5 -> 2` tls 均衡 | `peertls` | `peertls/<listen>#<list_name>#<strategy>` | `relay+tls` chain + selector |
| `7 -> 5 -> 3` ws 均衡 | `peerws` | `peerws/<listen>#<list_name>#<strategy>` | `relay+ws` chain + selector |
| `7 -> 5 -> 4` wss 均衡 | `peerwss` | `peerwss/<listen>#<list_name>#<strategy>` | `relay+wss` chain + selector |
| `7 -> 6 -> 1` CDN 不加密 | `cdnno` | `cdnno/<listen>#<ip:port>#<host>` | 直连 + `host` metadata |
| `7 -> 6 -> 2` CDN ws | `cdnws` | `cdnws/<listen>#<ip:port>#<host>` | `relay+ws` + `host` |
| `7 -> 6 -> 3` CDN wss | `cdnwss` | `cdnwss/<listen>#<ip:port>#<host>` | `relay+wss` + `host` |

## 代理类规则说明

### socks5

| 模式 | 输入 | `rawconf` |
| --- | --- | --- |
| 无认证 | 端口 | `socks/#__NOAUTH__#<port>` |
| 有认证 | 用户名、密码、端口 | `socks/<password>#<username>#<port>` |

### http

| 模式 | 输入 | `rawconf` |
| --- | --- | --- |
| 无认证 | 端口 | `http/#__NOAUTH__#<port>` |
| 有认证 | 用户名、密码、端口 | `http/<password>#<username>#<port>` |

### https

| 模式 | 输入 | `rawconf` |
| --- | --- | --- |
| 无认证 + 域名证书 | 端口、域名、证书方式 | `https/<listen>#<domain>#noauth\|\|\|<cert>\|<key>\|domain` |
| 无认证 + IP 证书 | 端口、IP、证书方式 | `https/<listen>#<ip>#noauth\|\|\|<cert>\|<key>\|ip` |
| 有认证 + 域名证书 | 端口、域名、用户名、密码 | `https/<listen>#<domain>#auth\|<user>\|<pass>\|<cert>\|<key>\|domain` |
| 有认证 + IP 证书 | 端口、IP、用户名、密码 | `https/<listen>#<ip>#auth\|<user>\|<pass>\|<cert>\|<key>\|ip` |

## 证书与端口行为

| 场景 | UFW 行为 | 自动 reload |
| --- | --- | --- |
| 新增普通代理端口 | 不主动管理业务端口放行 | 重建配置时重启 gost |
| 新增 HTTPS 代理 | 若 `ufw` 为 active，则证书申请前尝试放行 `80/tcp` | 证书安装后 `reloadcmd` 自动重启 gost |
| 删除 HTTPS 规则 | 不回收业务端口放行 | 重建配置时重启 gost |
