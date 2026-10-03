# This file is machine-specific. Generate it on the target server with:
#   sudo nixos-generate-config
# Then replace this file with the generated /etc/nixos/hardware-configuration.nix.
#
# Do NOT commit the real hardware-configuration.nix to a public repo — it may
# contain disk serial numbers and partition layouts specific to the machine.

{ config, lib, pkgs, ... }:

{
  # Placeholder — replace with actual hardware config from the target server.
  boot.initrd.availableKernelModules = [ ];
  boot.kernelModules = [ ];
  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };
  swapDevices = [ ];
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
