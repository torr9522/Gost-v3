# HTTPS 指南

## 支持的 HTTPS 代理类型

脚本中的 HTTPS 代理本质是：

- `handler: http`
- `listener: tls`

也就是 HTTP 代理协议，外层通过 TLS 提供 HTTPS 入口。

## 菜单路径

```text
7 -> 4 -> 4
```

即：

- `7` 新增 gost 转发配置
- `4` 代理服务
- `4` https

然后可继续选择：

- `1` 添加代理
- `2` 管理代理

## 添加 HTTPS 代理

### 无认证

输入顺序：

1. 选择 `无认证`
2. 输入监听端口
3. 选择证书方式

### 有认证

输入顺序：

1. 选择 `有认证`
2. 输入监听端口
3. 选择证书方式
4. 输入用户名
5. 输入密码

## 证书方式

### 1. 自动申请域名证书

适用场景：

- 已有域名
- 域名已解析到当前服务器

支持：

- HTTP-01
- Cloudflare DNS API

证书目录：

```text
/root/gost_cert/domain/<domain>/cert.pem
/root/gost_cert/domain/<domain>/key.pem
```

### 2. 自动申请 IP 证书

适用场景：

- 无域名
- 直接用公网 IP 提供 HTTPS 代理

实现：

- 使用 Let’s Encrypt
- 使用 `shortlived` certificate profile
- 走 `HTTP-01` standalone 验证

证书目录：

```text
/root/gost_cert/ip/<ip>/cert.pem
/root/gost_cert/ip/<ip>/key.pem
```

注意：

- 必须从公网访问到当前服务器的 `80/tcp`
- 脚本会自动确保 `80/tcp` 放行
- 这类证书为短期证书，依赖 `acme.sh` 自动续期

### 3. 使用已有证书

支持两种目录：

- 域名证书目录
- IP 证书目录

脚本只检查：

- `cert.pem`
- `key.pem`

是否存在于约定目录下。

## 自动续期

脚本通过 `acme.sh --installcert --reloadcmd "systemctl restart gost"` 处理证书安装。

这意味着：

- 初次签发完成后会自动重启 `gost`
- 后续续期完成后也会自动重启 `gost`

## UFW 行为

HTTPS 代理会触发两类端口同步：

- 业务监听端口是否开放：由宿主机自己的网络策略决定
- `80/tcp`：仅在证书申请阶段，如果检测到 `ufw` 为 active，脚本会尝试补开，供 ACME `HTTP-01` 使用

也就是说：

- 脚本不再统一管理业务端口的 `ufw`
- 如果宿主机像 `n-ui` 一样改用 `nftables`，脚本也不会主动去重新启用 `ufw`

## 管理 HTTPS 代理

管理入口：

```text
7 -> 4 -> 4 -> 2
```

当前支持：

- 查看 HTTPS 代理
- 删除 HTTPS 代理
- 重新申请证书

展示字段包括：

- 监听端口
- 绑定对象（域名/IP）
- 认证模式
- 用户名
- 证书类型（domain/ip）

## 常用示例

### 无认证 + IP 证书

```text
7
4
4
1
1
36569
2
45.77.246.87
```

### 有认证 + 域名证书

```text
7
4
4
1
2
443
1
your@email.com
proxy.example.com
1
admin
123456
```

## 故障排查

### IP 证书申请失败

优先检查：

- `80/tcp` 是否已放行
- 服务器是否能从公网访问 `http://<ip>/.well-known/acme-challenge/...`
- 云厂商安全组是否放行 `80/tcp`

### 域名证书申请失败

优先检查：

- 域名解析是否指向当前服务器
- `80/tcp` 是否可达
- Cloudflare API Key 是否正确

### 证书已签发但代理未生效

优先检查：

- `systemctl status gost`
- `/etc/gost/config.yaml`
- 证书路径是否存在
- 监听端口是否已被其他服务占用
