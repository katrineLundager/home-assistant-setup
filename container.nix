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
  services.clickhouse = {
    enable = true;
    serverConfig = {
      http_port = 8124;
      tcp_port = 9000;
      listen_host = "127.0.0.1";
    };
  };

  # ── ClickHouse Ingestor ─────────────────────────────────────────
  # Streams HA state_changed events into ClickHouse via WebSocket.
  # Token is mounted from the host via bindMount in flake.nix.
  systemd.services.clickhouse-ingestor = {
    description = "Stream Home Assistant state changes into ClickHouse";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "home-assistant.service" "clickhouse.service" ];

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
      CLICKHOUSE_PASSWORD = "";
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
