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

The ClickHouse password setup (below) additionally needs the
`/run/secrets/clickhouse-passwords.env` and `/run/secrets/clickhouse-users-d.yaml`
bind mounts and a host-side service that generates them — with the module, all
of this is handled automatically.

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

### ClickHouse users and passwords

ClickHouse only listens on `127.0.0.1` (HTTP 8124, native 9000 — shared with
the host), so it is not exposed to the LAN. Every user except `lovelace`
requires a password.

#### 1. Create the database secrets on the host

```fish
sudo mkdir -p /var/lib/secrets
echo "DEFAULT_PASSWORD=<superuser password>" | sudo tee /var/lib/secrets/clickhouse-passwords.env >/dev/null
echo "READER_PASSWORD=<read-only password>" | sudo tee -a /var/lib/secrets/clickhouse-passwords.env >/dev/null
sudo chmod 600 /var/lib/secrets/clickhouse-passwords.env
```

#### 2. Prepare the secrets on the host at every boot

The host needs a oneshot service (in `configuration.nix`) that copies the file
to `/run/secrets/` (tmpfs, wiped at boot) and renders the `default` password
into a users.d fragment. Both files are bind-mounted read-only into the
container by the module (`flake.nix`):

```nix
systemd.services.clickhouse-secrets = {
  description = "Prepare ClickHouse secrets for the ha-stack container";
  wantedBy = [ "multi-user.target" ];
  before = [ "container@ha-stack.service" ];
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
  };
  script = ''
    install -d -m 0755 /run/secrets
    umask 077
    . /var/lib/secrets/clickhouse-passwords.env
    : "''${DEFAULT_PASSWORD:?DEFAULT_PASSWORD is not set in /var/lib/secrets/clickhouse-passwords.env}"
    cp -- /var/lib/secrets/clickhouse-passwords.env /run/secrets/clickhouse-passwords.env
    chmod 600 /run/secrets/clickhouse-passwords.env
    # `default` lives in the stock users.xml and cannot be modified via SQL,
    # so its password is set through a users.d fragment instead.
    # The file must be readable by the container's clickhouse user (uid/gid 278).
    PW_ESC="''${DEFAULT_PASSWORD//\\/\\\\}"
    PW_ESC="''${PW_ESC//\"/\\\"}"
    printf 'users:\n  default:\n    password: "%s"\n' "$PW_ESC" \
      > /run/secrets/clickhouse-users-d.yaml
    chown root:278 /run/secrets/clickhouse-users-d.yaml
    chmod 640 /run/secrets/clickhouse-users-d.yaml
  '';
};
```

#### 3. Users

| User | Password | Access | Used by |
|---|---|---|---|
| `default` | `DEFAULT_PASSWORD` | full access, localhost only | ingestor (writes), interactive admin |
| `reader` | `READER_PASSWORD` | `SELECT` only | read-only queries |
| `lovelace` | none | `SELECT` only (`readonly` profile), localhost only | HA `command_line` sensor |

`reader` is created/updated at every container boot by the
`clickhouse-set-passwords` oneshot inside the container, which authenticates as
`default` with `DEFAULT_PASSWORD`.

#### 4. Ingestor database password

The ingestor writes as `default`, so the token file must also carry the
database password:

```fish
echo "CLICKHOUSE_PASSWORD=<same as DEFAULT_PASSWORD>" | sudo tee -a /var/lib/ha-stack/clickhouse-ingestor.env >/dev/null
```

Then refresh the secrets and restart the container:

```bash
sudo systemctl restart ha-stack-secret.service clickhouse-secrets.service
sudo nixos-container stop ha-stack && sudo nixos-container start ha-stack
```

#### 5. Connecting

`clickhouse-client` never prompts on its own — without credentials it fails
with `Code: 516`. Use `--ask-password` to be prompted:

```bash
clickhouse-client --ask-password --query "SELECT currentUser()"
# or non-interactively:
clickhouse-client --password "$DEFAULT_PASSWORD" --query "SELECT 1"
```

To change a password, edit `/var/lib/secrets/clickhouse-passwords.env`, then
restart `clickhouse-secrets.service` and the `ha-stack` container (ClickHouse
reads users.d only at startup).

### Dashboard charts backed by ClickHouse

The ingestor stores every state change with its full attributes as JSON
(`homeassistant.states.attributes`), so history is available for everything —
sun elevation, weather, prices — back to when ingestion started. No ingestor
change is needed for this; the charts query the stored data.

Three `command_line` sensors (in `container.nix`) query ClickHouse over
localhost as the read-only `lovelace` user and expose parallel arrays as
attributes (hourly averages over the last 7 days, hours in Europe/Copenhagen):

| Sensor | Queries |
|---|---|
| `sensor.clickhouse_sun_elevation` | `avg(elevation)` from `sun.sun` attributes |
| `sensor.clickhouse_temperature` | `avg(temperature)` from `weather.forecast_home` attributes |
| `sensor.clickhouse_nordpool_price` | `avg(state_float)` of `sensor.nordpool_kwh_dk1_dkk_3_10_0` |

The **ClickHouse** tab of the "A Hus!" dashboard (`home-assistant-dashboard.yaml`)
renders them with `apexcharts-card` charts: daily consumption, sun elevation,
temperature and spot price.

Notes:

- `sun.sun` has no temperature attribute — temperature comes from the weather
  entity (`weather.forecast_home`).
- The nordpool sensor's state is the current spot price and changes hourly, so
  its `state_float` history is the price series.
- Hours are formatted server-side in Europe/Copenhagen, so chart times match
  local time (the raw `last_updated` column is stored in UTC).

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



## Observe data coming in to clickhouse DB
To observe whether the database and ingestor are correctly set up you can query some data from the database.
`lovelace` is a passwordless read-only user (localhost only) meant for exactly this:
```fish
curl -s 'http://127.0.0.1:8124/?user=lovelace&database=homeassistant&query=SELECT+entity_id,state,last_updated+FROM+states+ORDER+BY+last_updated+DESC+LIMIT+10+FORMAT+PrettyCompact'
```


## Files

| File | Purpose |
|---|---|
| `flake.nix` | Exposes `nixosModules.default` — the container definition |
| `container.nix` | Inner container config (HA + ClickHouse + ingestor) |
| `nordpool.nix` | Nordpool custom component package |
| `clickhouse-ingestor.nix` | Ingestor package (from apbodrov/clickhouse-hassio) |
| `home-assistant-dashboard.yaml` | Lovelace dashboard config |
