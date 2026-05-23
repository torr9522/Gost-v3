# Multi-EasyGost一键脚本使用指南
***
## 感谢: 
1. 感谢 gost 项目的持续维护者们，当前脚本已升级适配 [go-gost/gost](https://github.com/go-gost/gost) v3，详细文档可查看[官方文档](https://gost.run)
2. 感谢 @风萧萧兮易水寒 大佬的[原始脚本](https://www.fiisi.com/?p=125)
3. 感谢 @ STSDUST 提供的EasyGost脚本（已删库），此脚本是基于其进行修改增强
***
## 简介

> 项目地址及帮助文档:  
> https://github.com/KANIKIG/Multi-EasyGost
***
## 脚本

* 启动脚本  
  `curl -fsSL -o gost.sh https://raw.githubusercontent.com/KANIKIG/Multi-EasyGost/v2/gost.sh && chmod +x gost.sh && ./gost.sh`  
* 再次运行本脚本只需要输入`./gost.sh`回车即可  

> 注：当前脚本已升级为 gost v3 方案，配置文件改为 YAML，并继续兼容脚本保存的旧规则格式

## 功能

### 原脚本功能

- 实现了systemd及gost YAML配置文件对gost进行管理
- 在不借助其他工具(如screen)的情况下实现多条转发规则同时生效
- 机器reboot后转发不失效
- 支持传输类型：
  - tcp+udp不加密转发
  -  relay+tls加密

### 此脚本新增功能

- 增加了传输类型选择功能
- 新支持传输类型
  - relay+ws
  - relay+wss
- 落地机一键创建 ss/socks5/http/https 代理 (gost 内置)
- 支持多传输类型的多落地简单型均衡负载
- ~~增加gost国内加速下载镜像~~（被恶意刷流量导致我损失，不再提供）
- 简单创建或删除gost定时重启任务
- 脚本自动检查更新
- 转发CDN自选节点ip
- 支持自定义 TLS 证书，落地可一键申请证书，中转可开启证书校验
- 支持 HTTPS 代理自动申请域名证书
- 支持 HTTPS 代理自动申请 IP 证书（Let’s Encrypt shortlived）
- 证书安装后自动重载 gost，续期时自动执行 reloadcmd
- 新增或删除规则时自动同步 UFW 放行对应 TCP 端口
- 当前安装源已切换到官方 `go-gost/gost` v3 发布版

## 功能展示

![iShot2020-12-14下午05.42.23.png](https://i.loli.net/2020/12/14/q75PO6s2DMIcUKB.png)

![iShot2020-12-14下午05.42.39.png](https://i.loli.net/2020/12/14/vzpGlWmPtCrneOY.png)

![2](https://i.loli.net/2020/10/16/fBHgwStVQxc821z.png)

![3](https://i.loli.net/2020/10/16/xgZ6eVAwSzDUFjO.png)

![4](https://i.loli.net/2020/10/16/lt6uAzI5X7yYWhr.png)

![iShot2020-12-14下午05.43.46.png](https://i.loli.net/2020/12/14/YjiFTMCKs8lANbI.png)

![iShot2020-12-14下午05.43.11.png](https://i.loli.net/2020/12/14/VIcQSsoUaqpzx5T.png)
