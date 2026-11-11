# VPN maintenance and Xray

## Optional interface traffic statistics

Install with `sudo apt update && sudo apt install vnstat`, then run `sudo systemctl enable --now vnstat`. The shared check uses vnStat 2.x's `--oneline` output for the default IPv4 interface. Missing vnStat is informational; an inactive service, unavailable interface or unsupported output is a warning. A newly initialized database may have no history yet. Statistics start after collection begins and measure total interface traffic, not Hysteria2/Xray separately or AWS billing. For manual queries, use `vnstat -i YOUR_INTERFACE -l` (Ctrl+C to stop), `vnstat -i YOUR_INTERFACE -d` (daily), and `vnstat -i YOUR_INTERFACE -m` (monthly).

Hysteria2 uses UDP 443; an independently installed Xray VLESS + REALITY service uses TCP 443. They can coexist because TCP and UDP are separate transports. This project installs Hysteria2, not Xray. Xray installation, credentials and client setup remain the operator's responsibility.

The diagnostics support `hysteria-server.service`, `/usr/local/bin/hysteria`, `/etc/hysteria/config.yaml`, and `xray.service`, `/usr/local/bin/xray`, `/usr/local/etc/xray/config.json`. Custom Xray paths require adaptation; validation of the standard file does not prove a custom service uses it. REALITY does not require the Hysteria2 Let's Encrypt certificate.

## Upgrade maintenance tools only

From a trusted checkout of this repository, without rerunning the server installer:

```bash
git pull --ff-only origin main
sudo install -m 0755 scripts/check-status.sh /usr/local/bin/hysteria-check
sudo install -m 0755 scripts/update-tools.sh /usr/local/bin/hysteria-update
sudo ln -sfn hysteria-check /usr/local/bin/vpn-check
sudo vpn-check
```

After this one-time upgrade, `sudo hysteria-update` updates the shared script and ensures the alias exists. It follows `main`, not the latest release. The checkout can be removed afterward. `hysteria-check [PUBLIC_IP]` and repository invocation remain supported. Use `vpn-check <PUBLIC_IP>` if automatic detection fails.

All diagnostics remain read-only, including Xray `run -test`. No configuration or raw journal entries are printed. Log summaries cover error-level entries available in the last 24 hours; missing retention cannot prove an error-free period. CPU load and uptime are informational; memory warns at 90%, disk at 80% and becomes critical at 90%. Permissions or unavailable checks produce warnings rather than a false PASS. Exit code 0 means no warnings/critical findings; 1 means attention is needed. Colors follow TTY, `NO_COLOR` and `TERM=dumb` behavior.

Keep private credentials outside Git. VLESS + REALITY deployments use a client UUID, a server private key and matching client public key, server name and short ID. Use placeholders such as `YOUR_UUID`, `YOUR_REALITY_PRIVATE_KEY`, `YOUR_REALITY_PUBLIC_KEY`, `YOUR_SERVER_NAME` and `YOUR_SHORT_ID` in shared notes. Never copy the live configuration into this repository.
