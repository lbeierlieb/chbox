{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  # Home is a tmpfs, so these are copied fresh on every boot.
  claudeJson = pkgs.writeText "claude.json" (
    builtins.toJSON {
      hasCompletedOnboarding = true;
      bypassPermissionsModeAccepted = true;
      projects."/repo".hasTrustDialogAccepted = true;
    }
  );
  claudeSettings = pkgs.writeText "claude-settings.json" (
    builtins.toJSON {
      skipDangerousModePermissionPrompt = true;
    }
  );
in
{
  imports = [ (modulesPath + "/profiles/minimal.nix") ];

  system.stateVersion = "26.05";
  networking.hostName = "chbox";

  # Direct kernel boot: no bootloader, no disk.
  boot.loader.grub.enable = false;
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtiofs"
    "virtio_blk"
    "ext4"
    "overlay"
  ];
  boot.initrd.kernelModules = [ "virtio_console" ];
  boot.kernelParams = [
    "console=hvc0"
    "quiet"
    "udev.log_level=3"
    "systemd.show_status=true"
  ];
  boot.consoleLogLevel = 3;

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = [ "mode=755" ];
  };
  # /nix/store = host store (read-only, virtiofs) + throwaway disk (writes).
  fileSystems."/nix/.ro-store" = {
    device = "nixstore";
    fsType = "virtiofs";
    options = [ "ro" ];
    neededForBoot = true;
  };
  fileSystems."/nix/.rw-store" = {
    device = "/dev/disk/by-label/chbox-store";
    fsType = "ext4";
    neededForBoot = true;
  };
  fileSystems."/nix/store" = {
    overlay = {
      lowerdir = [ "/nix/.ro-store" ];
      upperdir = "/nix/.rw-store/store";
      workdir = "/nix/.rw-store/work";
    };
    neededForBoot = true;
  };
  fileSystems."/repo" = {
    device = "repo";
    fsType = "virtiofs";
  };
  # Per-launch data from run.sh: claude-token, git-name, git-email.
  fileSystems."/run/chbox" = {
    device = "chbox";
    fsType = "virtiofs";
    options = [ "ro" ];
  };

  # Static addressing on the tap that run.sh sets up; filtering happens there,
  # outside the VM.
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.firewall.enable = false;
  networking.nameservers = [ "192.0.2.53" ];
  networking.enableIPv6 = false; # the namespace is IPv4-only (pasta -4)
  systemd.network.networks."10-uplink" = {
    matchConfig.Type = "ether";
    address = [ "10.200.0.2/24" ];
    gateway = [ "10.200.0.1" ];
  };

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

  nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";
  environment.systemPackages = [
    pkgs.git
    pkgs.claude-code
  ];
  # The store is read-only and the VM throwaway: updating in place can't work.
  environment.variables.DISABLE_AUTOUPDATER = "1";

  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    extraConfig = "set -g focus-events on"; # Claude Code asks for it
  };
  # On the console login: pick up the per-launch data, skip Claude's first-run
  # prompts, and start tmux with Claude in the first pane (a shell once Claude
  # exits). Leaving tmux ends the login; getty logs in again. `sudo poweroff`
  # exits the VM.
  programs.bash.loginShellInit = ''
    if [ -z "''${TMUX-}" ] && [ "$(tty)" = /dev/hvc0 ]; then
      if [ -s /run/chbox/claude-token ]; then
        export CLAUDE_CODE_OAUTH_TOKEN=$(< /run/chbox/claude-token)
      fi
      if [ -s /run/chbox/git-name ]; then
        export GIT_AUTHOR_NAME=$(< /run/chbox/git-name) GIT_COMMITTER_NAME=$(< /run/chbox/git-name)
      fi
      if [ -s /run/chbox/git-email ]; then
        export GIT_AUTHOR_EMAIL=$(< /run/chbox/git-email) GIT_COMMITTER_EMAIL=$(< /run/chbox/git-email)
      fi
      [ -e ~/.claude.json ] || install -m 600 ${claudeJson} ~/.claude.json
      mkdir -p ~/.claude
      [ -e ~/.claude/settings.json ] || install -m 600 ${claudeSettings} ~/.claude/settings.json
      exec tmux new-session -A -s main -c /repo \
        "claude --dangerously-skip-permissions; exec bash"
    fi
  '';

  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [ "dev" ];
    # nixosSystem pins nixpkgs in /etc/nix/registry.json; skip the global download.
    flake-registry = "";
  };
  nix.channel.enable = false;

  # The Nix database starts empty each boot: register the guest's own closure
  # (passed by the runner as chbox.registration=...) before nix-daemon starts.
  systemd.services.chbox-register-store = {
    # Same ordering as nixpkgs' register-nix-paths (qemu-vm.nix): early in
    # boot, before anything (including nix-daemon) can use the store.
    unitConfig.DefaultDependencies = false;
    wantedBy = [ "sysinit.target" ];
    before = [
      "sysinit.target"
      "shutdown.target"
      "nix-daemon.socket"
      "nix-daemon.service"
    ];
    after = [ "local-fs.target" ];
    conflicts = [ "shutdown.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if [[ "$(< /proc/cmdline)" =~ chbox.registration=([^ ]*) ]]; then
        ${config.nix.package}/bin/nix-store --load-db < "''${BASH_REMATCH[1]}"
      fi
    '';
  };

  # virtiofsd holds a host fd per inode the guest caches; make the guest
  # let go of them regularly so the count doesn't creep up to the limit.
  boot.kernel.sysctl."vm.vfs_cache_pressure" = 200;
  systemd.services.chbox-drop-inodes = {
    serviceConfig.Type = "oneshot";
    script = "echo 2 > /proc/sys/vm/drop_caches";
  };
  systemd.timers.chbox-drop-inodes = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "5min";
    };
  };
}
