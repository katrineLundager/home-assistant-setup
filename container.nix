# Inner NixOS config for the ha-stack container.
# Bundles Home Assistant + ClickHouse + ingestor so all three
# communicate over localhost inside the container.
#
# This file is imported by flake.nix's nixosModules.default, or can
# be used directly:
#   containers.ha-stack.config = import ./container.nix { inherit pkgs lib; };

{ pkgs, lib, ... }:

{
  system.stateVersion = "26.05";

  networking.firewall.allowedTCPPorts = [ 8123 ];

  time.timeZone = "Europe/Copenhagen";

  # ── Home Assistant ──────────────────────────────────────────────
  services.home-assistant = {
    enable = true;

    customComponents = [
      (pkgs.callPackage ./nordpool.nix { })
    ];

    extraComponents = [
      "met"
      "isal"
      "forecast_solar"
      "fronius"
      "sma"
    ];

    customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [
      apexcharts-card
    ];
    # Un-comment this section the first time you build (otherwise it does not produce
    # the symlink to ui_lovelace.yaml in /var/lib/hass/.
    #    lovelaceConfig = {
    #      title = "My Home";
    #      views = [{
    #        title = "Energy";
    #        path = "energy";
    #        cards = [
    #        { type = "markdown"; title = "Test Card"; content = "# Dashboard is working!"; }
    #        { type = "entities"; title = "All entities"; entities = []; }
    #        ];
    #      }];
    #    };

    lovelaceConfigFile = ./home-assistant-dashboard.yaml;

    config = {
      default_config = { };

      # Pulls a 14-day daily consumption aggregation out of ClickHouse and
      # exposes it as sensor.clickhouse_daily_consumption with `day` and
      # `consumption` array attributes (parallel arrays via FORMAT JSONColumns).
      # The apexcharts-card in home-assistant-dashboard.yaml reads those
      # attributes synchronously in its data_generator — no browser fetch, no
      # CORS, no LAN exposure of ClickHouse.
      #
      # NOTE: sum(state_float) per day mirrors HA's statistics `sum` (sum of all
      # sampled state values each day). For a monotonic energy counter you may
      # prefer the actual daily delta: max(state_float) - min(state_float).
      #
      # The sensors below expose other history the same way: sun elevation,
      # outdoor temperature and the nordpool spot price.
      command_line = [
        {
          sensor = [
            {
              name = "ClickHouse Daily Consumption";
              command = ''
                ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT toDate(last_updated) AS day, sum(state_float) AS consumption FROM homeassistant.states WHERE entity_id = 'sensor.main_energy' AND last_updated >= now() - INTERVAL 14 DAY GROUP BY day ORDER BY day"
              '';
              value_template = "{{ value_json.consumption | default([]) | sum }}";
              json_attributes = [
                "day"
                "consumption"
              ];
              scan_interval = 600;
            }
            # Hourly average sun elevation, from sun.sun's `elevation`
            # attribute (the ingestor stores full attributes as JSON).
            {
              name = "ClickHouse Sun Elevation";
              command = ''
                ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, avg(JSONExtractFloat(attributes, 'elevation')) AS elevation FROM homeassistant.states WHERE entity_id = 'sun.sun' AND JSONHas(attributes, 'elevation') AND last_updated >= now() - INTERVAL 7 DAY GROUP BY hour ORDER BY hour"
              '';
              value_template = "{{ value_json.elevation | default([]) | last | default(0) }}";
              json_attributes = [
                "hour"
                "elevation"
              ];
              scan_interval = 600;
            }
            # Hourly average outdoor temperature. sun.sun has no temperature
            # attribute — it lives on the weather entity.
            {
              name = "ClickHouse Temperature";
              command = ''
                ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, avg(JSONExtractFloat(attributes, 'temperature')) AS temperature FROM homeassistant.states WHERE entity_id = 'weather.forecast_home' AND JSONHas(attributes, 'temperature') AND last_updated >= now() - INTERVAL 7 DAY GROUP BY hour ORDER BY hour"
              '';
              value_template = "{{ value_json.temperature | default([]) | last | default(0) }}";
              json_attributes = [
                "hour"
                "temperature"
              ];
              scan_interval = 600;
            }
            # Hourly average nordpool spot price. The sensor's state is the
            # current price and changes hourly, so state_float is the series.
            {
              name = "ClickHouse Nordpool Price";
              command = ''
                ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, avg(state_float) AS price FROM homeassistant.states WHERE entity_id = 'sensor.nordpool_kwh_dk1_dkk_3_10_0' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 7 DAY GROUP BY hour ORDER BY hour"
              '';
              value_template = "{{ value_json.price | default([]) | last | default(0) }}";
              json_attributes = [
                "hour"
                "price"
              ];
              scan_interval = 600;
            }
          ];
        }
      ];

      lovelace.dashboards.nixos-lovelace = {
        mode = "yaml";
        filename = "ui-lovelace.yaml";
        title = "A Hus!";
        icon = "mdi:view-dashboard";
        show_in_sidebar = true;
      };
    };
  };

  # ── ClickHouse ──────────────────────────────────────────────────
  # HTTP port is 8124 (not 8123) to avoid conflict with HA inside the container.
  # Stays bound to 127.0.0.1: the command_line sensor below queries it over
  # localhost, so ClickHouse is never exposed to the LAN.
  services.clickhouse = {
    enable = true;
    serverConfig = {
      http_port = 8124;
      tcp_port = 9000;
      listen_host = "127.0.0.1";
    };

    # Read-only user used by the command_line sensor below. It is passwordless,
    # but the server only listens on 127.0.0.1 and `lovelace` can only SELECT,
    # as a least-privilege precaution. ClickHouse 26.x requires every
    # config-defined user to declare an authentication type, hence `no_password`.
    usersConfig = {
      profiles.readonly.readonly = 1;
      users.lovelace.profile = "readonly";
      users.lovelace.no_password = "";
      users.default.networks.ip = "127.0.0.1";

    };
  };

  # Create the read-only `reader` user. The `default` user's password is NOT
  # set here: it is defined in the stock users.xml, and config-managed users
  # cannot be modified via SQL. Its password comes from the bind-mounted
  # /etc/clickhouse-server/users.d/50-runtime-passwords.yaml instead, so this
  # oneshot authenticates as `default` with DEFAULT_PASSWORD from the start.
  systemd.services.clickhouse-set-passwords = {
    description = "Set ClickHouse user paswords from /run/Secrets";
    after = [ "clickhouse.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      . /run/secrets/clickhouse-passwords.env
      # clickhouse-client is not on the unit's PATH; use the store path directly.
      CH="${pkgs.clickhouse}/bin/clickhouse-client"

      for i in $(seq 1 30); do
        "$CH" --host 127.0.0.1 --password "$DEFAULT_PASSWORD" --query "SELECT 1" 2>/dev/null && break
        sleep 1
      done
      "$CH" --host 127.0.0.1 --password "$DEFAULT_PASSWORD" --query "SELECT 1" || { echo "ClickHouse not ready"; exit 1; }

      "$CH" --host 127.0.0.1 --password "$DEFAULT_PASSWORD" --query \
        "CREATE USER IF NOT EXISTS reader IDENTIFIED WITH scram_sha256_password BY '""$READER_PASSWORD""'"
      "$CH" --host 127.0.0.1 --password "$DEFAULT_PASSWORD" --query \
        "ALTER USER reader IDENTIFIED WITH scram_sha256_password BY '""$READER_PASSWORD""'"
      "$CH" --host 127.0.0.1 --password "$DEFAULT_PASSWORD" --query "GRANT SELECT ON *.* TO reader"
      echo "Reader user created/updated"

    '';
  };

  # ── ClickHouse Ingestor ─────────────────────────────────────────
  # Streams HA state_changed events into ClickHouse via WebSocket.
  # Token is mounted from the host via bindMount in flake.nix.
  systemd.services.clickhouse-ingestor = {
    description = "Stream Home Assistant state changes into ClickHouse";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network.target"
      "home-assistant.service"
      "clickhouse.service"
    ];

    serviceConfig = {
      ExecStart = "${pkgs.callPackage ./clickhouse-ingestor.nix { }}/bin/clickhouse-ingestor";
      Restart = "always";
      RestartSec = 10;
      EnvironmentFile = "/run/secrets/clickhouse-ingestor.env";
    };

    environment = {
      # HA WebSocket inside the container
      HA_WS_URL = "ws://localhost:8123/api/websocket";
      # ClickHouse HTTP inside the container (port 8124, not 8123)
      CLICKHOUSE_HOST = "127.0.0.1";
      CLICKHOUSE_PORT = "8124";
      CLICKHOUSE_USER = "default";
      # CLICKHOUSE_PASSWORD comes from /run/secrets/clickhouse-ingestor.env
      # (EnvironmentFile). Set it to the same value as DEFAULT_PASSWORD in
      # /var/lib/secrets/clickhouse-passwords.env.
      CLICKHOUSE_DATABASE = "homeassistant";
      CLICKHOUSE_TABLE = "states";
      # Tuning
      BATCH_SIZE = "500";
      FLUSH_INTERVAL = "5";
      INCLUDE_ATTRIBUTES = "true";
      # EXCLUDE_ENTITIES = "sensor.bad_entity,switch.noisy";
    };
  };
}
