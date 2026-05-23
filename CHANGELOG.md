# Changelog

## 3.0.0

- Migrate runtime from `gost v2` JSON config to `gost v3` YAML config.
- Replace old binary source with official `go-gost/gost` release packages.
- Add built-in `ss/socks5/http/https` proxy provisioning.
- Add HTTPS proxy with:
  - domain certificate auto-issue
  - IP certificate auto-issue
  - manual certificate reuse
  - certificate re-issue from management menu
- Add automatic `ufw` sync for business TCP ports and ACME `80/tcp`.
- Keep compatibility with existing `rawconf` rules while extending the format for HTTPS rules.
