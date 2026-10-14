{ lib, pkgs, modulesPath, ... }:
{
  imports = [ (modulesPath + "/profiles/minimal.nix") ];

  system.stateVersion = "26.05";
  networking.hostName = "chbox";

  # Direct kernel boot: no bootloader, no disk.
  boot.loader.grub.enable = false;
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [ "virtio_pci" "virtiofs" ];
  boot.initrd.kernelModules = [ "virtio_console" ];
  boot.kernelParams = [ "console=hvc0" "quiet" "udev.log_level=3" "systemd.show_status=true" ];
  boot.consoleLogLevel = 3;

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=755" ];
  };
  fileSystems."/nix/store" = {
    device = "nixstore";
    fsType = "virtiofs";
    options = [ "ro" ];
    neededForBoot = true;
  };
  fileSystems."/repo" = {
    device = "repo";
    fsType = "virtiofs";
  };

  networking.useDHCP = false;
  networking.firewall.enable = false;

  users.mutableUsers = false;
  users.allowNoPasswordLogin = true; # autologin only
  users.users.dev = {
    isNormalUser = true;
    uid = 1000; # mapped to the host user by virtiofsd, see run.sh
    extraGroups = [ "wheel" ];
  };
  security.sudo.wheelNeedsPassword = false;

  # serial-getty@hvc0 is started by systemd's getty generator from console=hvc0.
  services.getty.autologinUser = "dev";

  # The host passes its $TERM through, so ship terminfo for common terminals.
  environment.enableAllTerminfo = true;

  environment.systemPackages = [ pkgs.git ];

  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
  };
  # Leaving tmux ends the login; getty logs in again. `sudo poweroff` exits the VM.
  programs.bash.loginShellInit = ''
    if [ -z "''${TMUX-}" ] && [ "$(tty)" = /dev/hvc0 ]; then
      exec tmux new-session -A -s main -c /repo
    fi
  '';
}
