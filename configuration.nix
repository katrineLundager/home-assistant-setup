# Server configuration for Home Assistant + ClickHouse + ingestor.
# Deploy with: sudo nixos-rebuild switch --flake .#ha-server

{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
  ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  networking.hostName = "ha-server";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Copenhagen";

  i18n.defaultLocale = "en_GB.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "da_DK.UTF-8";
    LC_IDENTIFICATION = "da_DK.UTF-8";
    LC_MEASUREMENT = "da_DK.UTF-8";
    LC_MONETARY = "da_DK.UTF-8";
    LC_NAME = "da_DK.UTF-8";
    LC_NUMERIC = "da_DK.UTF-8";
    LC_PAPER = "da_DK.UTF-8";
    LC_TELEPHONE = "da_DK.UTF-8";
    LC_TIME = "da_DK.UTF-8";
  };

  users.users.katrine = {
    isNormalUser = true;
    description = "Katrine";
    extraGroups = [ "wheel" "networkmanager" ];
  };

  nixpkgs.config.allowUnfree = true;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

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
  services.clickhouse = {
    enable = true;
    serverConfig = {
      http_port = 8123;
      tcp_port = 9000;
      listen_host = "127.0.0.1";
    };
  };

  # ── ClickHouse Ingestor ─────────────────────────────────────────
  # Streams HA state_changed events into ClickHouse via WebSocket.
  # Create the env file on the server:
  #   sudo tee /run/secrets/clickhouse-ingestor.env <<EOF
  #   SUPERVISOR_TOKEN=your_long_lived_ha_token
  #   EOF
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
      # Connect to HA WebSocket directly (no Supervisor on NixOS)
      HA_WS_URL = "ws://localhost:8123/api/websocket";
      # ClickHouse connection
      CLICKHOUSE_HOST = "127.0.0.1";
      CLICKHOUSE_PORT = "8123";
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

  # ── Packages ───────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    git
    vim
    clickhouse
  ];

  programs.git.enable = true;

  services.openssh.enable = true;

  system.stateVersion = "26.05";
}
