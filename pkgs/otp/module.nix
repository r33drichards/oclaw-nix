{ config, lib, pkgs, ... }:

let
  cfg = config.services.opentripplanner;
  otpPkg = pkgs.callPackage ./default.nix {};
in
{
  options.services.opentripplanner = {
    enable = lib.mkEnableOption "OpenTripPlanner multimodal trip planner";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "HTTP port for the OTP API and web interface.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/otp";
      description = ''
        Directory containing GTFS feeds (*.gtfs.zip), OSM data (*.osm.pbf),
        build-config.json, and router-config.json. The graph will also be
        saved here after building.
      '';
    };

    jvmOpts = lib.mkOption {
      type = lib.types.str;
      default = "-Xmx4g -Xms2g";
      description = "JVM memory options for OpenTripPlanner.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the OTP port in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    # One-shot service to build the graph if it doesn't exist yet
    systemd.services.opentripplanner-build = {
      description = "OpenTripPlanner Graph Builder";
      after = [ "network.target" ];
      before = [ "opentripplanner.service" ];
      requiredBy = [ "opentripplanner.service" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        DynamicUser = true;
        StateDirectory = "otp";
        WorkingDirectory = cfg.dataDir;

        ExecStart = pkgs.writeShellScript "otp-build" ''
          if [ -f "${cfg.dataDir}/graph.obj" ] || [ -f "${cfg.dataDir}/streetGraph.obj" ]; then
            echo "Graph already exists in ${cfg.dataDir}, skipping build."
            exit 0
          fi

          # Check that we have at least some data to build from
          shopt -s nullglob
          osm_files=(${cfg.dataDir}/*.osm.pbf)
          gtfs_files=(${cfg.dataDir}/*.gtfs.zip)

          if [ ''${#osm_files[@]} -eq 0 ] && [ ''${#gtfs_files[@]} -eq 0 ]; then
            echo "ERROR: No .osm.pbf or .gtfs.zip files found in ${cfg.dataDir}"
            echo "Please add transit/OSM data before starting OTP."
            exit 1
          fi

          echo "Building OTP graph from data in ${cfg.dataDir}..."
          ${pkgs.jre_headless}/bin/java ${cfg.jvmOpts} \
            -jar ${otpPkg}/share/otp/otp-shaded-${otpPkg.version}.jar \
            --build --save ${cfg.dataDir}
        '';

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        PrivateTmp = true;
      };
    };

    # Long-running service that loads the graph and serves the API
    systemd.services.opentripplanner = {
      description = "OpenTripPlanner Trip Planning Server";
      after = [ "network.target" "opentripplanner-build.service" ];
      wants = [ "opentripplanner-build.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        StateDirectory = "otp";
        WorkingDirectory = cfg.dataDir;

        ExecStart = ''
          ${pkgs.jre_headless}/bin/java ${cfg.jvmOpts} \
            -jar ${otpPkg}/share/otp/otp-shaded-${otpPkg.version}.jar \
            --load --serve \
            --port ${toString cfg.port} \
            ${cfg.dataDir}
        '';

        Restart = "on-failure";
        RestartSec = "30s";

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        PrivateDevices = true;
      };
    };
  };
}
