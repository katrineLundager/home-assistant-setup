# home-assistant-setup

NixOS flake for running Home Assistant with long-term state history stored in ClickHouse.

## Purpose

Stores Home Assistant entity state changes (e.g. Fronius inverter data at 5s intervals) in ClickHouse for long-term retention and analytics. The built-in HA recorder (SQLite/PostgreSQL) is not efficient enough for high-frequency data over long periods.

## Architecture

```
Fronius inverter ──> Home Assistant ──(WebSocket: state_changed)──> ClickHouse Ingestor ──(HTTP INSERT)──> ClickHouse
```

- **Home Assistant** — collects data from Fronius, Nordpool, etc.
- **ClickHouse Ingestor** — streams HA state changes into ClickHouse via WebSocket
- **ClickHouse** — column-store database for long-term storage

## Status

Work in progress. Not yet tested on the target server.

## Deploy

```bash
git clone <repo-url> home-assistant-setup
cd home-assistant-setup

# Replace the placeholder hardware config with the real one:
sudo nixos-generate-config
cp /etc/nixos/hardware-configuration.nix ./hardware-configuration.nix

# Create the HA long-lived token:
sudo tee /run/secrets/clickhouse-ingestor.env <<EOF
SUPERVISOR_TOKEN=your_long_lived_ha_token
EOF

# Build and switch:
sudo nixos-rebuild switch --flake .#ha-server

# Updates:
git pull && sudo nixos-rebuild switch --flake .#ha-server
```
