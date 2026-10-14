{
  description = "cloud-hypervisor sandbox for AI-assisted development";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      guest = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./guest.nix ];
      };
      cfg = guest.config;
    in
    {
      packages.${system}.default = pkgs.writeShellApplication {
        name = "chbox";
        runtimeInputs = with pkgs; [ cloud-hypervisor virtiofsd coreutils ];
        text = ''
          KERNEL=${cfg.boot.kernelPackages.kernel.dev}/vmlinux
          INITRD=${cfg.system.build.initialRamdisk}/${cfg.system.boot.loader.initrdFile}
          TOPLEVEL=${cfg.system.build.toplevel}
        '' + builtins.readFile ./run.sh;
      };
    };
}
