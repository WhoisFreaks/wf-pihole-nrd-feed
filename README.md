# wf-pihole-nrd-feed

> Block newly registered domains in Pi-hole using the WhoisFreaks NRD feed. Configurable rolling-window blocklist (5/10/30 days) with daily auto-refresh, automatic Pi-hole subscription, and gravity reload — all in Docker.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Docker](https://img.shields.io/badge/docker-compose-2496ED.svg)](https://docs.docker.com/compose/)
[![Pi-hole v6](https://img.shields.io/badge/pi--hole-v6-96060C.svg)](https://pi-hole.net/)

---

## Why

Curated threat feeds arrive late. Palo Alto Networks' Unit 42 found that **over 70% of domains registered in the previous 32 days were malicious, suspicious, or NSFW** — and their published recommendation is to block NRDs outright.

This repo wires the [WhoisFreaks NRD feed](https://whoisfreaks.com/products/newly-registered-domains) into Pi-hole as a *rolling-window* blocklist. New domains roll on, expired ones roll off, Pi-hole picks up changes automatically every night.

## Features

- **Rolling window** — keep 5, 10, 14, or 30 days of NRDs. One env var.
- **Per-day caching** — only the new day downloads each night. No redundant API calls.
- **Auto-subscribe** — feed gets added to Pi-hole's Lists on first run. Zero UI clicks.
- **Auto gravity reload** — Pi-hole rebuilds after every fetch.
- **Self-contained cron** — schedule lives inside the container. Stop the stack, cron stops.
- **API key isolation** — key mounted read-only from the host. Never in compose, never in scripts.

## Quick start

```bash
# 1. Clone
git clone https://github.com/WhoisFreaks/wf-pihole-nrd-feed.git
cd wf-pihole-nrd-feed

# 2. Store your WhoisFreaks API key on the host
sudo mkdir -p /etc/whoisfreaks
echo "YOUR_API_KEY_HERE" | sudo tee /etc/whoisfreaks/apikey > /dev/null
sudo chmod 600 /etc/whoisfreaks/apikey

# 3. Set the Pi-hole admin password in docker-compose.yml, then start
docker compose up -d
docker logs -f nrd-feed-fetcher
```

First run takes 2-3 minutes (downloads 10 days of data). When you see `Gravity reload complete`, open **http://localhost:8080/admin**, log in, and check **Lists** — the WhoisFreaks entry should be there with a few million domains loaded.

## Configuration

Set these in the `feed-fetcher` service of `docker-compose.yml`:

| Variable | Default | What it does |
|---|---|---|
| `WINDOW_DAYS` | `10` | Days of NRDs to keep in the blocklist |
| `FEED_TYPES` | `gtld cctld` | Which WhoisFreaks feeds to pull |
| `CRON_SCHEDULE` | `0 3 * * *` | When to refresh (standard cron) |
| `AUTO_SUBSCRIBE` | `true` | Auto-add the feed URL to Pi-hole's Lists |
| `TRIGGER_GRAVITY` | `true` | Auto-reload Pi-hole gravity after each fetch |
| `FEED_URL` | `http://feed-server/nrd.txt` | URL registered in Pi-hole's adlist |
| `PIHOLE_CONTAINER` | `pihole` | Container name for `docker exec` |

## Picking your window length

- **5 days** — minimum viable. Lowest false-positive rate. Catches burn-and-rotate phishing.
- **10 days** — recommended default. Catches most malware C2 staging plus phishing campaigns.
- **30 days** — Unit 42's official recommendation. Maximum coverage, more allowlist work.

Change `WINDOW_DAYS` any time. The next cron tick adjusts the cache automatically.

## How it works

Three containers:

- `pihole` — DNS resolver and admin UI
- `feed-server` — nginx serving the combined blocklist on the internal Docker network
- `feed-fetcher` — runs cron internally; downloads NRDs, caches per-day files, rebuilds the combined list, subscribes Pi-hole, reloads gravity

Each day's NRDs cache as a separate file (`2026-05-21_gtld.txt`). The combined `nrd.txt` is rebuilt atomically from in-window cache files. The fetcher talks to Pi-hole via the mounted Docker socket to handle subscription and gravity reload.

## Troubleshooting

**Port 53 in use** (Ubuntu/Debian):
```bash
sudo systemctl disable --now systemd-resolved
sudo rm /etc/resolv.conf
echo "nameserver 1.1.1.1" | sudo tee /etc/resolv.conf
```

**List appears in Pi-hole but no domains blocked.** Run gravity manually once: `docker exec pihole pihole -g`.

**"API key file not readable."** Check `/etc/whoisfreaks/apikey` exists on the host and the bind mount in `docker-compose.yml` matches.

**Memory pressure on small devices.** Drop `WINDOW_DAYS` to 5 or 7. A 30-day window can hit 5-8M domains — slow on a Pi Zero.

## License

[MIT](LICENSE)
