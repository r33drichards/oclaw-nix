{
  description = "oclaw NixOS environment — XFCE desktop + Chromium + OpenClaw gateway";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, comin }:
  let
    system = "aarch64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # Full system config — comin inside slot1 switches to this
    nixosConfigurations.slot1 = nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        ({ ... }: {
          # Slot1 network identity
          networking.hostName = "slot1";
          networking.useNetworkd = true;
          systemd.network.enable = true;
          systemd.network.networks."10-lan" = {
            matchConfig.Type = "ether";
            networkConfig = {
              Address = "10.1.0.2/24";
              Gateway = "10.1.0.1";
              DNS = "10.1.0.1";
            };
          };

          # SSH access
          services.openssh.enable = true;
          users.users.root.openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII4mlN4JTkdx3C7iBmMF5HporlQygDE2tjN77IE0Ezxn root@hypervisor"
          ];

          nix.settings.experimental-features = [ "nix-command" "flakes" ];
          system.stateVersion = "24.05";

          # Microvm boot — no traditional bootloader, root on virtio disk
          boot.loader.grub.enable = false;
          fileSystems."/" = { device = "/dev/vdb"; fsType = "ext4"; };
        })
      ];
    };

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

      # OpenClaw gateway — installed via npm on first start, then kept up to date
      # nix-openclaw doesn't support aarch64-linux so we use npm directly
      users.users.openclaw = {
        isSystemUser = true;
        group = "openclaw";
        home = "/var/lib/openclaw";
        createHome = true;
      };
      users.groups.openclaw = {};

      systemd.services.openclaw-gateway = {
        description = "OpenClaw gateway";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          OPENCLAW_STATE_DIR = "/var/lib/openclaw/state";
          HOME = "/var/lib/openclaw";
          npm_config_prefix = "/var/lib/openclaw/.npm-global";
          # Point OpenClaw at LiteLLM on the hypervisor bridge gateway
          OPENAI_API_BASE = "http://10.1.0.1:4000";
          OPENAI_API_KEY = "dummy";
        };
        path = [ pkgs.nodejs pkgs.bash pkgs.coreutils ];
        serviceConfig = {
          User = "openclaw";
          WorkingDirectory = "/var/lib/openclaw";
          # Install/update openclaw on every start, then run gateway
          ExecStartPre = pkgs.writeScript "openclaw-install" ''
            #!${pkgs.bash}/bin/bash
            set -e
            mkdir -p /var/lib/openclaw/state /var/lib/openclaw/.npm-global
            ${pkgs.nodejs}/bin/npm install -g openclaw@latest --prefix /var/lib/openclaw/.npm-global
          '';
          ExecStart = "/var/lib/openclaw/.npm-global/bin/openclaw gateway --port 18789";
          Restart = "on-failure";
          RestartSec = "10s";
          StateDirectory = "openclaw";
        };
      };

      environment.systemPackages = with pkgs; [
        chromium
        git
        nodejs
      ];
    };
  };
}

