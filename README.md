# home-assistant-setup

NixOS flake module that bundles Home Assistant + ClickHouse + ingestor into a single declarative container. Import it on any NixOS machine with one line.

## Purpose

Stores Home Assistant entity state changes (e.g. Fronius inverter data at 5s intervals) in ClickHouse for long-term retention and analytics. The built-in HA recorder (SQLite/PostgreSQL) is not efficient enough for high-frequency data over long periods.

## Architecture

```
┌─ Host (any NixOS machine) ──────────────────────────────┐
│  configuration.nix                                      │
│    modules = [ ha-stack.nixosModules.default ]          │
│                                                         │
│    ┌───────────────────────────────────────────┐        │
│    │ Container: ha-stack                       │        │
│    │  ├─ Home Assistant  (port 8123)            │        │
│    │  ├─ ClickHouse      (port 8124 internal)   │        │
│    │  └─ Ingestor        (localhost websocket)  │        │
│    │  All three talk via localhost inside      │        │
│    └────────────────┬──────────────────────────┘        │
│                     │ port 8123 forwarded to host        │
└─────────────────────┴───────────────────────────────────┘
```

- **Home Assistant** — collects data from Fronius, Nordpool, etc.
- **ClickHouse Ingestor** — streams HA state changes into ClickHouse via WebSocket. Adapted from [apbodrov/clickhouse-hassio](https://github.com/apbodrov/clickhouse-hassio) (ClickHouse Ingestor add-on)
- **ClickHouse** — column-store database for long-term storage

## Status

Work in progress. Not yet tested on the target server.

## Usage

### With a flake (recommended)

Add to your `flake.nix`:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  ha-stack.url = "github:katrineLundager/home-assistant-setup";
};

outputs = { self, nixpkgs, ha-stack, ... }: {
  nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
    modules = [
      ./configuration.nix
      ha-stack.nixosModules.default
    ];
  };
};
```

### Without a flake

```nix
containers.ha-stack = {
  autoStart = true;
  forwardPorts = [
    { containerPort = 8123; hostPort = 8123; protocol = "tcp"; }
  ];
  bindMounts = {
    "/run/secrets/clickhouse-ingestor.env" = {
      hostPath = "/run/secrets/clickhouse-ingestor.env";
      isReadOnly = true;
    };
  };
  config = import ./path/to/container.nix { inherit pkgs lib; };
};
```

### Before first start

Create the HA long-lived access token on the host:

```bash
sudo mkdir -p /run/secrets
echo "SUPERVISOR_TOKEN=your_long_lived_ha_token" | sudo tee /run/secrets/clickhouse-ingestor.env
```

Then rebuild:

```bash
sudo nixos-rebuild switch
```

HA will be available at `http://localhost:8123`.

## Files

| File | Purpose |
|---|---|
| `flake.nix` | Exposes `nixosModules.default` — the container definition |
| `container.nix` | Inner container config (HA + ClickHouse + ingestor) |
| `nordpool.nix` | Nordpool custom component package |
| `clickhouse-ingestor.nix` | Ingestor package (from apbodrov/clickhouse-hassio) |
| `home-assistant-dashboard.yaml` | Lovelace dashboard config |
