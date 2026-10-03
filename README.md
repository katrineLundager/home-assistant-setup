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

Without the module, you must create `/run/secrets/clickhouse-ingestor.env`
manually on the host before the container starts — and recreate it after every
reboot, since `/run` is tmpfs.

### Providing the HA access token

The ingestor needs a long-lived HA access token. The module's
`ha-stack-secret.service` writes it to `/run/secrets/clickhouse-ingestor.env`
at boot (and after each rebuild), so it survives the tmpfs `/run` wipe.

Choose one of two options in your NixOS config:

**Recommended — `tokenFile` (token stays out of the Nix store):**

```bash
# Create once on the host:
sudo install -d -m 700 /var/lib/ha-stack
sudo tee /var/lib/ha-stack/clickhouse-ingestor.env >/dev/null <<EOF
SUPERVISOR_TOKEN=your_long_lived_ha_token
EOF
sudo chmod 600 /var/lib/ha-stack/clickhouse-ingestor.env
```

```nix
services.ha-stack.tokenFile = "/var/lib/ha-stack/clickhouse-ingestor.env";
```

**Quick — `supervisorToken` (token ends up in the world-readable Nix store):**

```nix
services.ha-stack.supervisorToken = "your_long_lived_ha_token";
```

### Start

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
