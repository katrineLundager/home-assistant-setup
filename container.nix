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

  # Without this the container generates an empty /etc/resolv.conf (no
  # nameserver lines), so every DNS lookup inside it fails — e.g. the
  # nordpool integration dies with ClientConnectorDNSError at boot and
  # its sensor stays "unavailable" until a restart. The container shares
  # the host network stack, but resolv.conf generation is per-container.
  # Same router DNS as the host, with a public resolver as fallback.
  networking.nameservers = [ "192.168.1.1" "9.9.9.9" ];

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
      "shelly"
      "peblar"
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
      # NOTE: HA's command_line schema wants one list item per sensor, with
      # `sensor` being that sensor's config dict (not a list of sensors).
      command_line = [
        {
          sensor = {
            name = "ClickHouse Daily Consumption From NRGI";
            # Combines two sources: the NRGI kWh samples (summed directly)
            # and the smart meter's real power (W), which is integrated
            # time-weighted: each sample's watts times the seconds until
            # the next sample, summed per day and divided by 3.6e6 (J per
            # kWh). NOTE: leadInFrame needs an explicit frame ending at
            # 1 FOLLOWING — with the default frame it has no following row
            # and returns the DateTime zero value (1970-01-01) instead of
            # NULL, yielding dt of -1.8e9 seconds. greatest(..., 0)
            # neutralizes the zero default on the final sample of each day.
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT day, sum(consumption) AS consumption FROM (SELECT toDate(last_updated) AS day, sum(state_float) AS consumption FROM homeassistant.states WHERE entity_id = 'sensor.clickhouse_main_consumption_nrgi' AND last_updated >= now() - INTERVAL 14 DAY GROUP BY day UNION ALL SELECT day, sum(w * dt) / 3600000 AS consumption FROM (SELECT day, w, dt FROM (SELECT toDate(last_updated) AS day, state_float AS w, greatest(dateDiff('second', last_updated, leadInFrame(last_updated) OVER (PARTITION BY toDate(last_updated) ORDER BY last_updated ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING)), 0) AS dt FROM homeassistant.states WHERE entity_id = 'sensor.smart_meter_ts_65a_3_real_power' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 14 DAY)) GROUP BY day) GROUP BY day ORDER BY day"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) }}";
            unit_of_measurement = "kWh";
            json_attributes = [
              "day"
              "consumption"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # -> sensor.clickhouse_hourly_consumption_from_nrgi
            name = "ClickHouse Monthly Consumption From NRGI";
            # Same two-source combination as the daily sensor: NRGI kWh
            # summed directly + smart meter W integrated time-weighted
            # per month (watts x seconds until next sample / 3.6e6),
            # with the same explicit-window-frame fix as the daily query.
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT month, sum(consumption) AS consumption FROM (SELECT formatDateTime(toStartOfMonth(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS month, sum(state_float) AS consumption FROM homeassistant.states WHERE entity_id = 'sensor.clickhouse_main_consumption_nrgi' GROUP BY month UNION ALL SELECT month, sum(w * dt) / 3600000 AS consumption FROM (SELECT month, w, dt FROM (SELECT formatDateTime(toStartOfMonth(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS month, state_float AS w, greatest(dateDiff('second', last_updated, leadInFrame(last_updated) OVER (PARTITION BY toStartOfMonth(last_updated) ORDER BY last_updated ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING)), 0) AS dt FROM homeassistant.states WHERE entity_id = 'sensor.smart_meter_ts_65a_3_real_power' AND state_float IS NOT NULL)) GROUP BY month) GROUP BY month ORDER BY month"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) | round(2) }}";
            unit_of_measurement = "kWh";
            json_attributes = [
              "month"
              "consumption"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # -> sensor.clickhouse_hourly_consumption_from_nrgi
            name = "ClickHouse Hourly Consumption From NRGI";
            # Same two-source combination as the daily sensor: NRGI kWh
            # summed directly + smart meter W integrated time-weighted
            # per hour (watts x seconds until next sample / 3.6e6),
            # with the same explicit-window-frame fix as the daily query.
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT hour, sum(consumption) AS consumption FROM (SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, sum(state_float) AS consumption FROM homeassistant.states WHERE entity_id = 'sensor.clickhouse_main_consumption_nrgi' AND last_updated >= now() - INTERVAL 14 DAY GROUP BY hour UNION ALL SELECT hour, sum(w * dt) / 3600000 AS consumption FROM (SELECT hour, w, dt FROM (SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, state_float AS w, greatest(dateDiff('second', last_updated, leadInFrame(last_updated) OVER (PARTITION BY toStartOfHour(last_updated) ORDER BY last_updated ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING)), 0) AS dt FROM homeassistant.states WHERE entity_id = 'sensor.smart_meter_ts_65a_3_real_power' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 14 DAY)) GROUP BY hour) GROUP BY hour ORDER BY hour"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) }}";

            unit_of_measurement = "kWh";
            json_attributes = [
              "hour"
              "consumption"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # -> sensor.clickhouse_hourly_generation_from_solarnet
            # Hourly photovoltaic energy from solarnet_power_photovoltaics,
            # an instantaneous power (W) sampled event-driven. Energy is the
            # same time-weighted staircase integral as the smart-meter half
            # of the hourly consumption query: each sample's watts times the
            # seconds until the next sample, summed per hour / 3.6e6 (kWh).
            # leadInFrame needs the explicit frame ending at 1 FOLLOWING —
            # with the default frame it returns the DateTime zero value
            # instead of NULL; greatest(..., 0) neutralizes it.
            name = "ClickHouse Hourly Generation From SolarNet";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT hour, sum(consumption) AS consumption FROM (SELECT hour, sum(w * dt) / 3600000 AS consumption FROM (SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, state_float AS w, greatest(dateDiff('second', last_updated, leadInFrame(last_updated) OVER (PARTITION BY toStartOfHour(last_updated) ORDER BY last_updated ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING)), 0) AS dt FROM homeassistant.states WHERE entity_id = 'sensor.solarnet_power_photovoltaics' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 14 DAY) GROUP BY hour) GROUP BY hour ORDER BY hour"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) }}";
            unit_of_measurement = "kWh";

            json_attributes = [
              "hour"
              "consumption"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # -> sensor.clickhouse_daily_generation_from_solarnet
            # Today's total photovoltaic energy (kWh), for the PV gauge:
            # the same staircase integral as the hourly sensor above,
            # summed over the whole day instead of grouped per hour.
            # toStartOfDay(now()) is evaluated in the container's local
            # timezone (Europe/Copenhagen), matching the hour labels.
            # Mirrors the hourly sensor's value_template exactly: JSONColumns
            # always returns arrays, so the state must be taken with | last —
            # otherwise the state renders as "[13.6]" (non-numeric), which HA
            # rejects and the sensor is stuck in unknown.
            name = "ClickHouse Daily Generation From SolarNet";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT sum(w * dt) / 3600000 AS consumption FROM (SELECT state_float AS w, greatest(dateDiff('second', last_updated, leadInFrame(last_updated) OVER (ORDER BY last_updated ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING)), 0) AS dt FROM homeassistant.states WHERE entity_id = 'sensor.solarnet_power_photovoltaics' AND state_float IS NOT NULL AND last_updated >= toStartOfDay(now()))"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) | round(2) }}";
            unit_of_measurement = "kWh";
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # Hourly average sun elevation, from sun.sun's `elevation`
            # attribute (the ingestor stores full attributes as JSON).
            name = "ClickHouse Sun Elevation";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, avg(JSONExtractFloat(attributes, 'elevation')) AS elevation FROM homeassistant.states WHERE entity_id = 'sun.sun' AND JSONHas(attributes, 'elevation') AND last_updated >= now() - INTERVAL 14 DAY GROUP BY hour ORDER BY hour"
            '';
            value_template = "{{ value_json.elevation | default([]) | last | default(0) }}";
            unit_of_measurement = "°";
            json_attributes = [
              "hour"
              "elevation"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # Hourly average outdoor temperature. sun.sun has no temperature
            # attribute — it lives on the weather entity.
            name = "ClickHouse Temperature";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, avg(JSONExtractFloat(attributes, 'temperature')) AS temperature FROM homeassistant.states WHERE entity_id = 'weather.forecast_home' AND JSONHas(attributes, 'temperature') AND last_updated >= now() - INTERVAL 7 DAY GROUP BY hour ORDER BY hour"
            '';
            value_template = "{{ value_json.temperature | default([]) | last | default(0) }}";
            unit_of_measurement = "°C";
            json_attributes = [
              "hour"
              "temperature"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # Nordpool spot price from the latest throttled ClickHouse row.
            # The ingestor throttles nordpool to one row per hour (see
            # THROTTLE_ENTITIES); every stored row still carries the full
            # today/tomorrow price arrays, so we read them from that row's
            # attributes JSON. The last_updated <= now() guard keeps the
            # query on strictly historical rows.
            # raw_today/raw_tomorrow arrive as JSON-encoded strings; the
            # dashboard data_generator does JSON.parse() on them.
            name = "ClickHouse Nordpool Price";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT state_float AS price, JSONExtractRaw(attributes, 'raw_today') AS raw_today, JSONExtractRaw(attributes, 'raw_tomorrow') AS raw_tomorrow, JSONExtractRaw(attributes, 'today') AS today, JSONExtractRaw(attributes, 'tomorrow') AS tomorrow FROM homeassistant.states WHERE entity_id = 'sensor.nordpool_kwh_dk1_dkk_3_10_0' AND state_float IS NOT NULL AND last_updated <= now() ORDER BY last_updated DESC LIMIT 1"
            '';
            value_template = "{{ value_json.price | default(0) }}";
            unit_of_measurement = "DKK/kWh";
            json_attributes = [
              "raw_today"
              "raw_tomorrow"
              "today"
              "tomorrow"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # 15-min nordpool spot prices for history graphs (1w and longer).
            # Plain state_float time series: one row per 15-min price slot
            # arrives live from the ingestor (no throttle), and the period
            # before that was materialized the same way by backfill_nordpool.sh.
            # Duplicate slots collapse in avg(). NOTE: DK1 is a 15-min market,
            # so last_updated slots nicely onto toStartOfFifteenMinutes.
            # 31 days of 15-min slots (~3k points) covers a 1w/1mo card; for
            # 3m/5y add a sensor with a coarser GROUP BY (hour/day/week) to
            # keep the attribute payload small. The attribute name stays
            # "hour" for the dashboard data_generator.
            name = "ClickHouse Nordpool History";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfFifteenMinutes(last_updated), '%Y-%m-%dT%H:%i:00', 'Europe/Copenhagen') AS hour, avg(state_float) AS price FROM homeassistant.states WHERE entity_id = 'sensor.nordpool_kwh_dk1_dkk_3_10_0' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 31 DAY GROUP BY hour ORDER BY hour"
            '';
            value_template = "{{ value_json.price | default([]) | last | default(0) }}";
            unit_of_measurement = "DKK/kWh";
            json_attributes = [
              "hour"
              "price"
            ];
            # Prices only change every 15 min, so polling faster is wasted work.
            scan_interval = 300;
          };
        }
        {
          sensor = {
            # Hourly energy delta for the Shelly motorcycle charger.
            # motorcykel_output_energy is a monotonic total counter, so the
            # per-hour consumption is last_value - first_value within the hour
            # (argMax/argMin by last_updated). Rows with state_float NULL
            # (entity "unavailable" while the Shelly sleeps) are excluded.
            name = "ClickHouse Car Energy";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, argMax(state_float, last_updated) AS energy FROM homeassistant.states WHERE entity_id = 'sensor.peblar_ev_charger_lifetime_energy' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 14 DAY GROUP BY hour ORDER BY hour"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) }}";
            unit_of_measurement = "kWh";
            json_attributes = [
              "hour"
              "energy"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # Hourly energy delta for the Shelly motorcycle charger.
            # motorcykel_output_energy is a monotonic total counter, so the
            # per-hour consumption is last_value - first_value within the hour
            # (argMax/argMin by last_updated). Rows with state_float NULL
            # (entity "unavailable" while the Shelly sleeps) are excluded.
            name = "ClickHouse Motorcycle Energy";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfHour(last_updated), '%Y-%m-%dT%H:00:00', 'Europe/Copenhagen') AS hour, argMax(state_float, last_updated) AS energy FROM homeassistant.states WHERE entity_id = 'sensor.motorcykel_output_energy' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 14 DAY GROUP BY hour ORDER BY hour"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) }}";
            unit_of_measurement = "kWh";
            json_attributes = [
              "hour"
              "energy"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # Per-minute energy consumption for the Peblar car charger, kWh.
            # Unlike the motorcycle charger (a monotonic energy counter,
            # where argMax - argMin works), peblar_ev_charger_power is an
            # instantaneous power in W, sampled event-driven (a row only on
            # change). Energy is therefore a staircase integral: each
            # sample's power is held until the next sample:
            #   kWh = sum(power_W * seconds_to_next_sample) / 3600 / 1000
            # leadInFrame needs an explicit frame ending at 1 FOLLOWING —
            # with the default frame (RANGE UNBOUNDED PRECEDING TO CURRENT
            # ROW) it has no following row and returns the DateTime zero
            # value (1970-01-01) instead of NULL, yielding dt of -1.8e9
            # seconds and huge negative kWh. On the final sample there is
            # no next row, so guard with next_ts > last_updated (same fix
            # as the smart-meter query above).
            # NOTE: %i is minutes in ClickHouse formatDateTime (%M = month).
            name = "ClickHouse Car Consumption";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(s.m, '%Y-%m-%dT%H:%i:00', 'Europe/Copenhagen') AS minute, s.kwh AS consumption FROM (SELECT toStartOfMinute(last_updated) AS m, sum(if(next_ts > last_updated, state_float * dateDiff('second', last_updated, next_ts), 0) / 3600 / 1000) AS kwh FROM (SELECT last_updated, state_float, leadInFrame(last_updated) OVER w AS next_ts FROM homeassistant.states WHERE entity_id = 'sensor.peblar_ev_charger_power' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 48 HOUR WINDOW w AS (ORDER BY last_updated ROWS BETWEEN CURRENT ROW AND 1 FOLLOWING)) AS d GROUP BY m) AS s ORDER BY m"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) }}";
            unit_of_measurement = "kWh";
            json_attributes = [
              "minute"
              "consumption"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # Hourly energy delta for the Shelly motorcycle charger.
            # motorcykel_output_energy is a monotonic total counter, so the
            # per-hour consumption is last_value - first_value within the hour
            # (argMax/argMin by last_updated). Rows with state_float NULL
            # (entity "unavailable" while the Shelly sleeps) are excluded.
            name = "ClickHouse Motorcycle Consumption";
            command = ''
              ${pkgs.curl}/bin/curl -s 'http://127.0.0.1:8124/?user=lovelace&default_format=JSONColumns' --data "SELECT formatDateTime(toStartOfMinute(last_updated), '%Y-%m-%dT%H:%i:00', 'Europe/Copenhagen') AS minute, argMax(state_float, last_updated) - argMin(state_float, last_updated) AS consumption FROM homeassistant.states WHERE entity_id = 'sensor.motorcykel_output_energy' AND state_float IS NOT NULL AND last_updated >= now() - INTERVAL 48 HOUR GROUP BY minute ORDER BY minute"
            '';
            value_template = "{{ value_json.consumption | default([]) | last | default(0) }}";
            unit_of_measurement = "kWh";
            json_attributes = [
              "minute"
              "consumption"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # -> sensor.clickhouse_lux_0xfd01
            # Hourly avg lux from the remote weather-station ClickHouse
            # (default.sensor_0xfd01). TZ=... is required because the NixOS
            # clickhouse-client has no /usr/share/zoneinfo and fails on
            # DateTime values without it.
            name = "ClickHouse Lux 0xfd01";
            command = ''
              TZ=Europe/Copenhagen ${pkgs.clickhouse}/bin/clickhouse-client --host 192.168.1.194 --port 9000 --user reader --password 'RtWyZAT6CiqaH9cY6RfdJfSi7E4urEiK' --query "SELECT formatDateTime(toStartOfHour(time), '%Y-%m-%dT%H:00:00') AS hour, avg(lux) AS lux FROM default.sensor_0xfd01 WHERE time >= now() - INTERVAL 14 DAY GROUP BY hour ORDER BY hour FORMAT JSONColumns"
            '';
            value_template = "{{ value_json.lux | default([]) | last | default(0) }}";
            unit_of_measurement = "lux";
            json_attributes = [
              "hour"
              "lux"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # -> sensor.clickhouse_temperature_0xfd01
            name = "ClickHouse Temperature 0xfd01";
            command = ''
              TZ=Europe/Copenhagen ${pkgs.clickhouse}/bin/clickhouse-client --host 192.168.1.194 --port 9000 --user reader --password 'RtWyZAT6CiqaH9cY6RfdJfSi7E4urEiK' --query "SELECT formatDateTime(toStartOfHour(time), '%Y-%m-%dT%H:00:00') AS hour, avg(temperature) AS temperature FROM default.sensor_0xfd01 WHERE time >= now() - INTERVAL 14 DAY GROUP BY hour ORDER BY hour FORMAT JSONColumns"
            '';
            value_template = "{{ value_json.temperature | default([]) | last | default(0) }}";
            unit_of_measurement = "°C";
            json_attributes = [
              "hour"
              "temperature"
            ];
            scan_interval = 5;
          };
        }
        {
          sensor = {
            # -> sensor.clickhouse_temperature_0xfd01
            name = "ClickHouse Rain 0xfd01";
            command = ''
              TZ=Europe/Copenhagen ${pkgs.clickhouse}/bin/clickhouse-client --host 192.168.1.194 --port 9000 --user reader --password 'RtWyZAT6CiqaH9cY6RfdJfSi7E4urEiK' --query "SELECT formatDateTime(toStartOfHour(time), '%Y-%m-%dT%H:00:00') AS hour, avg(rain_1hr) AS rain FROM default.sensor_0xfd01 WHERE time >= now() - INTERVAL 14 DAY GROUP BY hour ORDER BY hour FORMAT JSONColumns"
            '';
            value_template = "{{ value_json.temperature | default([]) | last | default(0) }}";
            unit_of_measurement = "0.01mm";
            json_attributes = [
              "hour"
              "rain"
            ];
            scan_interval = 5;
          };
        }
      ];

      # Workaround for the nordpool component not picking up day-ahead
      # prices (custom-components/nordpool issues #528 / #539): prices
      # publish ~13:00 CET, but the integration often keeps a stale/empty
      # raw_tomorrow until restarted. If tomorrow's prices are still
      # missing after publication, reload the config entry — the same
      # fresh fetch a container rebuild forces. Second trigger at 14:30
      # covers late publications (Nordpool can delay to ~14:00).
      automation = [
        {
          alias = "Reload Nordpool for tomorrow prices";
          id = "nordpool_reload_tomorrow";
          triggers = [
            { trigger = "time"; at = "13:30:00"; }
            { trigger = "time"; at = "14:30:00"; }
          ];
          conditions = [
            {
              condition = "template";
              value_template = "{{ state_attr('sensor.nordpool_kwh_dk1_dkk_3_10_0', 'raw_tomorrow') in (none, []) }}";
            }
          ];
          actions = [
            {
              action = "homeassistant.reload_config_entry";
              target.entity_id = "sensor.nordpool_kwh_dk1_dkk_3_10_0";
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
      # No per-entity throttling: nordpool is on the 15-min DK1 market, so
      # its state (the current price) changes once per 15-min slot and the
      # sensor fires ~96 times/day naturally — every slot's price is stored
      # with its full raw_today/raw_tomorrow attribute arrays.
      # Format: entity_id=min_seconds;...
      THROTTLE_ENTITIES = "";
    };
  };
}
