# 架构说明

## 文件结构

- `gost.sh`
  - 主脚本，包含安装、规则录入、证书申请、UFW 同步、配置渲染。
- `gost.service`
  - `systemd` 服务模板，运行 `gost -C /etc/gost/config.yaml`。
- `config.yaml`
  - 占位配置模板；当没有业务规则时使用。
- `README.md`
  - 使用说明。
- `docs/MENU_TREE.md`
  - 菜单树。
- `docs/SECONDARY_DEVELOPMENT.md`
  - 二开入口说明。
- `docs/PUBLISH_CHECKLIST.md`
  - 发布到你自己的远程仓库前需要替换的内容。

## 配置存储

- 业务规则持久化在 `/etc/gost/rawconf`。
- 运行配置渲染到 `/etc/gost/config.yaml`。
- 负载均衡节点列表保存在 `/etc/gost/lists/*.txt`。

## 证书目录

- 域名证书：
  - `/root/gost_cert/domain/<domain>/cert.pem`
  - `/root/gost_cert/domain/<domain>/key.pem`
- IP 证书：
  - `/root/gost_cert/ip/<ip>/cert.pem`
  - `/root/gost_cert/ip/<ip>/key.pem`

## HTTPS 规则格式

HTTPS 单独使用扩展后的 `rawconf` 格式：

```text
https/<listen_port>#<bind_name>#<auth_mode>|<username>|<password>|<cert_path>|<key_path>|<cert_kind>
```

示例：

```text
https/443#proxy.example.com#auth|admin|123456|/root/gost_cert/domain/proxy.example.com/cert.pem|/root/gost_cert/domain/proxy.example.com/key.pem|domain
https/36569#45.77.246.87#noauth|||/root/gost_cert/ip/45.77.246.87/cert.pem|/root/gost_cert/ip/45.77.246.87/key.pem|ip
```

## UFW 行为

- 当前脚本不再接管业务端口的 `ufw` 放行。
- 默认假设业务端口是否开放由宿主机自身网络策略决定。
- 仅在证书申请阶段，如果检测到 `ufw` 处于 `active` 状态，脚本会尝试补开 `80/tcp`，供 ACME `HTTP-01` 使用。
- 如果 `ufw` 处于 `inactive`，脚本不会主动启用它。
