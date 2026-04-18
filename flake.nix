{
  description = "oclaw NixOS environment — XFCE desktop + Chromium + OpenClaw gateway";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    comin = {
      url = "github:nlewo/comin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, comin, sops-nix }:
  let
    system = "aarch64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    # Build tools that postdate nixos-25.05: rolldown, pnpm_10, fetchPnpmDeps
    unstable = nixpkgs-unstable.legacyPackages.${system};
    # Vendored package with sandbox fixes (see pkgs/openclaw/default.nix)
    openclaw-base = unstable.callPackage ./pkgs/openclaw {};
    openclaw = pkgs.callPackage ./pkgs/openclaw-plugins { openclaw = openclaw-base; };
    graphhopper = pkgs.callPackage ./pkgs/graphhopper {};
    otp = pkgs.callPackage ./pkgs/otp {};
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

          # SSH access. UseDNS off so inbound reverse-DNS lookups don't hang
          # when Tailscale or upstream DNS is unhealthy.
          services.openssh = {
            enable = true;
            settings.UseDNS = false;
          };
          users.users.root.openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHJNEMM9i3WgPeA5dDmU7KMWTCcwLLi4EWfX8CKXuK7s robertwendt@Roberts-Laptop.local"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINlI6KJHGNUzVJV/OpBQPrcXQkYylvhoM3XvWJI1/tiZ"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKBlj6rlbIbhrnBIGBx7Kg5lCFcG5Kx7IdoCxCLpoSGF root@hypervisor"
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
      imports = [
        comin.nixosModules.comin
        sops-nix.nixosModules.sops
        ./pkgs/graphhopper/module.nix
        ./pkgs/otp/module.nix
        # slot-telemetry disabled — boot wedge still under investigation
        # ./modules/slot-telemetry.nix
      ];

      services.dbus.enable = true;

      # DEBUG: forward all journal entries to serial console so we can
      # diagnose boot wedges via the hypervisor's microvm@slot1 journal.
      services.journald.extraConfig = ''
        ForwardToConsole=yes
        TTYPath=/dev/ttyAMA0
        MaxLevelConsole=info
      '';

      # GitOps: Comin polls this repo and applies nixosConfigurations.<hostname>
      services.comin = {
        enable = true;
        remotes = [{
          name = "origin";
          url = "https://github.com/r33drichards/oclaw-nix.git";
          branches.main.name = "main";
          poller.period = 15;
        }];
      };

      # sops-nix secret management
      sops = {
        defaultSopsFile = ./secrets/secrets.yaml;
        age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
        secrets = {
          "exa_api_key" = {
            owner = "openclaw";
          };
          "transit_511_api_key" = {
            owner = "openclaw";
          };
        };
      };

      # Radicale CalDAV/CardDAV server
      services.radicale = {
        enable = true;
        settings = {
          server = {
            hosts = [ "0.0.0.0:5232" "[::]:5232" ];
            ssl = true;
            certificate = "/etc/radicale/ssl/cert.pem";
            key = "/etc/radicale/ssl/key.pem";
          };
          auth = {
            type = "htpasswd";
            htpasswd_filename = "/etc/radicale/users";
            htpasswd_encryption = "bcrypt";
          };
          storage = {
            filesystem_folder = "/var/lib/radicale/collections";
          };
        };
        rights = {
          root = {
            user = ".+";
            collection = "";
            permissions = "R";
          };
          principal = {
            user = ".+";
            collection = "{user}";
            permissions = "RW";
          };
          calendars = {
            user = ".+";
            collection = "{user}/[^/]+";
            permissions = "rw";
          };
        };
      };

      # Create htpasswd file and SSL certs for Radicale declaratively
      systemd.tmpfiles.rules = [
        "d /etc/radicale 0700 radicale radicale -"
        "d /etc/radicale/ssl 0700 radicale radicale -"
        ''f /etc/radicale/users 0600 radicale radicale - robert:$2b$05$NLnP8RRR.e13vS4xzinTdeKtoc7XNlWOq3liopxOcSkEvCVGzJtG.''
      ];

      # Generate self-signed TLS cert for Radicale if missing
      systemd.services.radicale-cert = {
        description = "Generate Radicale self-signed TLS certificate";
        before = [ "radicale.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [ pkgs.openssl ];
        script = ''
          if [ ! -f /etc/radicale/ssl/cert.pem ]; then
            openssl req -x509 -newkey rsa:2048 \
              -keyout /etc/radicale/ssl/key.pem \
              -out /etc/radicale/ssl/cert.pem \
              -days 3650 -nodes \
              -subj "/CN=10.1.0.2" \
              -addext "subjectAltName=IP:10.1.0.2"
            chown radicale:radicale /etc/radicale/ssl/key.pem /etc/radicale/ssl/cert.pem
            chmod 600 /etc/radicale/ssl/key.pem
            chmod 644 /etc/radicale/ssl/cert.pem
          fi
        '';
      };

      # GraphHopper routing engine — California OSM data
      # TEMPORARILY DISABLED: graph-cache/properties corrupted after an
      # interrupted restart, crash-looping blocked sshd/openclaw. Re-enable
      # after wiping /var/lib/graphhopper/graph-cache on slot1.
      services.graphhopper = {
        enable = false;
        osmFile = "/var/lib/graphhopper/california-latest.osm.pbf";
        dataDir = "/var/lib/graphhopper";
        port = 8989;
        profiles = [ "car" "foot" "bike" ];
        chProfiles = [ "car" ];
        dataAccess = "MMAP";
        jvmOpts = "-Xmx2g -Xms1g";
        openFirewall = true;
      };

      # OpenTripPlanner — multimodal transit routing (Bay Area)
      # TEMPORARILY DISABLED: graph-builder has been failing for a while;
      # probably same corrupted-cache class of issue. Re-enable after cleanup.
      services.opentripplanner = {
        enable = false;
        dataDir = "/var/lib/otp";
        port = 8080;
        jvmOpts = "-Xmx4g -Xms2g";
        openFirewall = true;
      };

      # Tailscale VPN — DISABLED: it was hijacking DNS to dns.nextdns.io
      # (blocked by hypervisor SNI filter), breaking all name resolution in
      # the guest. Access to slot1 still works via the hypervisor's own
      # Tailscale subnet routing (10.1.0.0/24 is advertised).
      services.tailscale.enable = false;

      # Tailscale-autoconnect disabled while tailscale is off (see above).

      # Open Radicale port on LAN (only reachable via Tailscale/local network)
      networking.firewall.allowedTCPPorts = [ 5232 ];

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

      # OpenClaw gateway — built from source via nixpkgs-unstable (supports aarch64-linux)
      users.users.openclaw = {
        isSystemUser = true;
        group = "openclaw";
        home = "/var/lib/openclaw";
        createHome = true;
        shell = pkgs.bash;
        extraGroups = [ "wheel" ];
      };

      # Passwordless sudo for openclaw
      security.sudo.extraRules = [{
        users = [ "openclaw" ];
        commands = [{ command = "ALL"; options = [ "NOPASSWD" ]; }];
      }];
      users.groups.openclaw = {};

      systemd.services.openclaw-gateway = {
        description = "OpenClaw gateway";
        after = [ "network.target" "sops-nix.service" ];
        wantedBy = [ "multi-user.target" ];
        environment = {
          OPENCLAW_STATE_DIR = "/var/lib/openclaw/state";
          HOME = "/var/lib/openclaw";
          LITELLM_API_KEY = "dummy";
        };
        serviceConfig = {
          User = "openclaw";
          WorkingDirectory = "/var/lib/openclaw";
          ExecStartPre = pkgs.writeShellScript "openclaw-init" ''
            mkdir -p /var/lib/openclaw/state
          '';
          ExecStart = pkgs.writeShellScript "openclaw-start" ''
            export OPENCLAW_STATE_DIR="/var/lib/openclaw/state"
            export HOME="/var/lib/openclaw"
            export LITELLM_API_KEY="dummy"
            if [ -f /run/secrets/exa_api_key ]; then
              export EXA_API_KEY="$(cat /run/secrets/exa_api_key)"
            fi
            exec ${openclaw}/bin/openclaw gateway --port 18789
          '';
          Restart = "always";
          RestartSec = "10s";
          StateDirectory = "openclaw";
        };
      };

      environment.systemPackages = with pkgs; [
        age
        chromium
        git
        nodejs
        openssl
        otp
        (python3.withPackages (ps: [ ps.ortools ]))
        sops
        ssh-to-age
        openclaw
      ];
    };
  };
}
