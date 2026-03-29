{ config, lib, pkgs, ... }:

let
  cfg = config.services.graphhopper;

  graphhopperPkg = pkgs.callPackage ./default.nix {};

  configFile = pkgs.writeText "graphhopper-config.yml" ''
    graphhopper:
      datareader.file: ${cfg.osmFile}
      graph.location: ${cfg.dataDir}/graph-cache

      profiles:
    ${lib.concatMapStringsSep "\n" (p: "    - name: ${p}\n      custom_model_files: [${p}.json${if (p == "foot" || p == "bike") then ", ${p}_elevation.json" else ""}]") cfg.profiles}

      profiles_ch:
    ${lib.concatMapStringsSep "\n" (p: "    - profile: ${p}") cfg.chProfiles}

      profiles_lm: []

      graph.encoded_values: |
        car_access, car_average_speed, country, road_class, roundabout, max_speed,
        foot_access, foot_average_speed, foot_priority, foot_road_access, hike_rating, average_slope,
        bike_access, bike_average_speed, bike_priority, bike_road_access, bike_network, mtb_rating, ferry_speed

      import.osm.ignored_highways: ""

      graph.elevation.provider: srtm

      prepare.min_network_size: 200
      prepare.subnetworks.threads: 1

      graph.dataaccess.default_type: ${cfg.dataAccess}

      routing.snap_preventions_default: tunnel, bridge, ferry
      routing.non_ch.max_waypoint_distance: 1000000

    server:
      application_connectors:
      - type: http
        port: ${toString cfg.port}
        bind_host: ${cfg.bindHost}
        max_request_header_size: 50k
      request_log:
        appenders: []
      admin_connectors:
      - type: http
        port: ${toString cfg.adminPort}
        bind_host: ${cfg.bindHost}
  '';
in
{
  options.services.graphhopper = {
    enable = lib.mkEnableOption "GraphHopper routing engine";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8989;
      description = "HTTP port for the GraphHopper API.";
    };

    adminPort = lib.mkOption {
      type = lib.types.port;
      default = 8990;
      description = "Admin HTTP port for GraphHopper health checks.";
    };

    bindHost = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Address to bind the HTTP server to.";
    };

    osmFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to the OpenStreetMap .osm.pbf data file.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/graphhopper";
      description = "Directory for GraphHopper graph cache and data.";
    };

    profiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "car" "foot" "bike" ];
      description = "Routing profiles to enable.";
    };

    chProfiles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "car" ];
      description = "Profiles to prepare with Contraction Hierarchies (speed mode).";
    };

    dataAccess = lib.mkOption {
      type = lib.types.enum [ "RAM_STORE" "MMAP" ];
      default = "MMAP";
      description = "Graph data access type. MMAP uses less heap; RAM_STORE is faster.";
    };

    jvmOpts = lib.mkOption {
      type = lib.types.str;
      default = "-Xmx2g -Xms1g";
      description = "JVM memory options.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the GraphHopper port in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.graphhopper = {
      description = "GraphHopper Routing Engine";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        DynamicUser = true;
        StateDirectory = "graphhopper";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${pkgs.jre_headless}/bin/java ${cfg.jvmOpts} -jar ${graphhopperPkg}/share/graphhopper/graphhopper-web-11.0.jar server ${configFile}";
        Restart = "on-failure";
        RestartSec = "10s";

        # Hardening
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        ReadOnlyPaths = [ (builtins.dirOf cfg.osmFile) ];
        PrivateTmp = true;
      };
    };
  };
}
