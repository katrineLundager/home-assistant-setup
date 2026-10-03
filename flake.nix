{
  description = "Home Assistant + ClickHouse container module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
  in {
    # Import this module on any NixOS machine to get the ha-stack container.
    #
    #   inputs.ha-stack.url = "github:katrineLundager/home-assistant-setup";
    #   modules = [ ha-stack.nixosModules.default ];
    #
    # Or without a flake:
    #   containers.ha-stack.config = import ./path/to/container.nix { inherit pkgs lib; };
    nixosModules.default = { pkgs, lib, config, ... }:
      let
        cfg = config.services.ha-stack;
      in {
        options.services.ha-stack = {
          # Long-lived Home Assistant access token for the clickhouse-ingestor.
          # WARNING: when set, this value is embedded in the world-readable
          # Nix store. Prefer `tokenFile` for real secrets.
          supervisorToken = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = ''
              Home Assistant long-lived access token for the clickhouse-ingestor.
              Ends up in the Nix store — prefer `tokenFile` for real secrets.
            '';
          };

          # Persistent host file whose contents are copied to
          # /run/secrets/clickhouse-ingestor.env at boot, keeping the token
          # out of the Nix store.
          tokenFile = lib.mkOption {
            # String, not `path`, so the file is NOT imported into the Nix store.
            type = lib.types.nullOr lib.types.str;
            default = null;
            example = "/var/lib/ha-stack/clickhouse-ingestor.env";
            description = ''
              Persistent host path (as a string) to a file whose contents
              are copied to /run/secrets/clickhouse-ingestor.env at boot.
              Takes precedence over `supervisorToken` and keeps the token
              out of the Nix store. Create the file once on the host:
                sudo install -m 600 /dev/null /var/lib/ha-stack/clickhouse-ingestor.env
                sudo tee -a /var/lib/ha-stack/clickhouse-ingestor.env >/dev/null <<EOF
                SUPERVISOR_TOKEN=your_long_lived_ha_token
                EOF
            '';
          };
        };

        config = {
          containers.ha-stack = {
            autoStart = true;

            # Forward HA web UI to host
            forwardPorts = [
              {
                containerPort = 8123;
                hostPort = 8123;
                protocol = "tcp";
              }
            ];

            # The secret file is prepared at boot by ha-stack-secret.service
            # below and bind-mounted read-only into the container.
            bindMounts = {
              "/run/secrets/clickhouse-ingestor.env" = {
                hostPath = "/run/secrets/clickhouse-ingestor.env";
                isReadOnly = true;
              };
            };

            config = import ./container.nix { inherit pkgs lib; };
          };

          # Prepares /run/secrets/clickhouse-ingestor.env on the host at boot
          # (and after each activation) so the container can bind-mount it.
          # /run is tmpfs, so the file must be recreated every boot.
          systemd.services.ha-stack-secret = {
            description = "Prepare /run/secrets/clickhouse-ingestor.env for the ha-stack container";
            wantedBy = [ "multi-user.target" ];
            before = [ "container@ha-stack.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              install -d -m 0755 /run/secrets
              umask 077
              ${lib.optionalString (cfg.tokenFile != null) ''
                cp -- "${cfg.tokenFile}" /run/secrets/clickhouse-ingestor.env
              ''}
              ${lib.optionalString (cfg.tokenFile == null) ''
                printf 'SUPERVISOR_TOKEN=%s\n' \
                  '${lib.escapeShellArg cfg.supervisorToken}' \
                  > /run/secrets/clickhouse-ingestor.env
              ''}
              chmod 600 /run/secrets/clickhouse-ingestor.env
            '';
          };
        };
      };
  };
}
