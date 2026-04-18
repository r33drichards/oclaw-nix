# modules/slot-telemetry.nix
# Per-slot OpenTelemetry collector for slot1 (oclaw-nix).
# Ships hostmetrics + journald logs via OTLP/gRPC to the hypervisor-side
# otelcol at 10.1.0.1:4317 (bridge gateway for br-slot1).
#
# Kept in oclaw-nix (not in simple-microvm-infra) because in-VM Comin on slot1
# polls this repo and runs `nixos-rebuild switch`. Any otelcol config defined
# only in the hypervisor-built runner would be wiped by that in-VM reconfigure.
{ config, pkgs, ... }:

{
  services.opentelemetry-collector = {
    enable = true;
    package = pkgs.opentelemetry-collector-contrib;
    settings = {
      receivers = {
        hostmetrics = {
          collection_interval = "30s";
          scrapers = {
            cpu = {};
            load = {};
            memory = {};
            disk = {};
            filesystem = {};
            network = {};
            paging = {};
          };
        };
        journald = {
          directory = "/var/log/journal";
          units = [];
          priority = "info";  # floor: info and higher severity (warn/err/crit/...); debug filtered
        };
      };

      processors = {
        batch = {
          timeout = "10s";
          send_batch_size = 1024;
        };
        resource.attributes = [
          { key = "slot.id"; value = config.networking.hostName; action = "upsert"; }
        ];
        memory_limiter = {
          check_interval = "5s";
          limit_percentage = 75;
          spike_limit_percentage = 20;
        };
      };

      exporters.otlp = {
        endpoint = "10.1.0.1:4317";
        tls.insecure = true;
      };

      service.pipelines = {
        metrics = {
          receivers = [ "hostmetrics" ];
          processors = [ "memory_limiter" "resource" "batch" ];
          exporters = [ "otlp" ];
        };
        logs = {
          receivers = [ "journald" ];
          processors = [ "memory_limiter" "resource" "batch" ];
          exporters = [ "otlp" ];
        };
      };
    };
  };

  # Persistent journald so the receiver has a source (default is "auto" which
  # leaves /var/log/journal unpopulated on some boots).
  services.journald.storage = "persistent";
}
