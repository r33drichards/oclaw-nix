#!/usr/bin/env bash
# Fetch Bay Area GTFS data for OpenTripPlanner
set -euo pipefail

DATA_DIR="${1:-/var/lib/otp}"
mkdir -p "$DATA_DIR"

echo "Downloading BART GTFS..."
curl -L -o "$DATA_DIR/bart.gtfs.zip" "https://www.bart.gov/dev/schedules/google_transit.zip"

echo "Downloading SFMTA/Muni GTFS..."
curl -L -o "$DATA_DIR/sfmta.gtfs.zip" "https://gtfs.sfmta.com/transitdata/google_transit.zip"

echo "Downloading Caltrain GTFS..."
curl -L -o "$DATA_DIR/caltrain.gtfs.zip" "https://www.caltrain.com/Assets/GTFS/caltrain/CT-GTFS.zip"

echo "Downloading AC Transit GTFS..."
curl -L -o "$DATA_DIR/actransit.gtfs.zip" "https://api.actransit.org/transit/gtfs/download"

echo "Downloading VTA GTFS..."
curl -L -o "$DATA_DIR/vta.gtfs.zip" "https://data.vta.org/dataset/vta-gtfs/resource/12345/download/gtfs.zip"

echo "Symlinking California OSM data..."
ln -sf /var/lib/graphhopper/california-latest.osm.pbf "$DATA_DIR/california.osm.pbf"

echo "Done! GTFS feeds in $DATA_DIR"
ls -lh "$DATA_DIR"
