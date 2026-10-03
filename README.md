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
`ha-stack-secret.service` copies it from a persistent host file to
`/run/secrets/clickhouse-ingestor.env` at boot (and after each rebuild),
so it survives the tmpfs `/run` wipe.

#### 1. Create a long-lived access token in Home Assistant

1. Open `http://localhost:8123` and log in.
2. Click your profile picture (bottom-left).
3. Scroll to **Long-Lived Access Tokens** (bottom of the page).
4. Click **Create Token**, give it a name (e.g. `clickhouse-ingestor`).
5. Copy the token — it is shown only once.

#### 2. Write it to a file on the host

```fish
sudo mkdir -p /var/lib/ha-stack
echo "SUPERVISOR_TOKEN=<paste your token here>" | sudo tee /var/lib/ha-stack/clickhouse-ingestor.env >/dev/null
sudo chmod 600 /var/lib/ha-stack/clickhouse-ingestor.env
```

The module defaults `tokenFile` to this path, so no extra NixOS config is
needed. If you want a different path, set it in your system config:

```nix
services.ha-stack.tokenFile = "/var/lib/ha-stack/clickhouse-ingestor.env"
```


#### 3. Apply and verify

```bash
sudo nixos-rebuild switch
sudo cat /run/secrets/clickhouse-ingestor.env   # should show SUPERVISOR_TOKEN=<long string>
```

### Adding the Nordpool integration

The Nordpool custom component is packaged via `nordpool.nix` and bundled
into the container automatically. To activate it:

1. Open `http://localhost:8123`.
2. Go to **Settings → Devices & Services → Add Integration**.
3. Search for **Nordpool** and select it.
4. Configure the region and currency (e.g. DK1, DKK).
5. Entities like `sensor.nordpool_kwh_dk1_dkk_3_10_0_raw_today` will appear
   and their state changes will be captured by the ingestor automatically.

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
