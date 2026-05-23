# 二开说明

## 入口函数

- 菜单入口：
  - `main`
  - `main_menu`
- 新增规则主流程：
  - `add_rule_interactive`
  - `save_rule_record`
  - `rebuild_and_restart_gost`
- 配置渲染：
  - `parse_rule_record`
  - `append_rule`
  - `render_config`

## 代理相关

- 代理菜单入口：
  - `select_proxy_rule_type`
  - `select_proxy_action`
- 代理管理：
  - `manage_proxy_rules`

## HTTPS 相关

- HTTPS 证书交互：
  - `prompt_https_cert_mode`
- 证书申请：
  - `issue_domain_cert`
  - `issue_ip_cert`
  - `resolve_existing_cert_paths`
- 证书目录：
  - `cert_dir_for_kind`

## UFW 相关

- `collect_required_tcp_ports`
- `ensure_ufw_rule`
- `delete_ufw_rule`
- `sync_ufw_ports`

## 建议的二开方式

- 新增规则类型时，优先补：
  - 菜单分支
  - `save_rule_record` 的存储格式
  - `parse_rule_record`
  - `append_rule`
  - `show_all_conf`
- 不要直接在多个菜单分支里重复写 `systemctl restart gost` 或 `ufw` 逻辑。
  - 统一走 `rebuild_and_restart_gost`。
