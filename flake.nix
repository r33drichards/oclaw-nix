{
  description = "oclaw NixOS environment — XFCE desktop + Chromium";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, comin }: {
    nixosModules.default = { pkgs, lib, ... }: {
      imports = [ comin.nixosModules.comin ];

      # GitOps: Comin polls this repo and applies nixosConfigurations.<hostname>
      services.comin = {
        enable = true;
        remotes = [{
          name = "origin";
          url = "https://github.com/r33drichards/oclaw-nix.git";
          branches.main.name = "main";
        }];
      };

      # XFCE desktop
      services.xserver = {
        enable = true;
        desktopManager.xfce.enable = true;
        displayManager.lightdm.enable = true;
      };

      # Remote desktop access via RDP
      # Connect: ssh -L 3389:10.1.0.2:3389 root@<hypervisor> then RDP to localhost:3389
      services.xrdp = {
        enable = true;
        defaultWindowManager = "xfce4-session";
        openFirewall = false;
      };

      environment.systemPackages = with pkgs; [
        chromium
        git
      ];
    };
  };
}
