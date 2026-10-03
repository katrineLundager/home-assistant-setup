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
    nixosModules.default = { pkgs, lib, ... }: {
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

        # Mount the HA long-lived token from the host into the container.
        # Create it on the host with:
        #   sudo tee /run/secrets/clickhouse-ingestor.env <<EOF
        #   SUPERVISOR_TOKEN=your_long_lived_ha_token
        #   EOF
        bindMounts = {
          "/run/secrets/clickhouse-ingestor.env" = {
            hostPath = "/run/secrets/clickhouse-ingestor.env";
            isReadOnly = true;
          };
        };

        config = import ./container.nix { inherit pkgs lib; };
      };
    };
  };
}
