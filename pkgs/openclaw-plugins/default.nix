# Wraps an OpenClaw package with additional bundled plugins.
# Uses runCommand to build a merged tree with symlinks to the
# original package plus custom plugin directories copied in.
{ lib, runCommand, openclaw }:

let
  # Each subdirectory here is a plugin (must contain openclaw.plugin.json + index.ts)
  pluginDirs = {
    exa-search = ./exa-search;
    itinerary-planner = ./itinerary-planner;
  };
in
runCommand "openclaw-with-plugins-${openclaw.version}" {
  inherit openclaw;
  meta = (openclaw.meta or {}) // {
    description = "${openclaw.meta.description or "OpenClaw"} (with custom plugins)";
  };
} ''
  # Mirror the entire openclaw tree as symlinks
  mkdir -p $out
  for item in $openclaw/*; do
    ln -s "$item" "$out/$(basename "$item")"
  done

  # Replace lib with a partial copy so we can modify extensions
  rm $out/lib
  mkdir -p $out/lib
  for item in $openclaw/lib/*; do
    ln -s "$item" "$out/lib/$(basename "$item")"
  done

  # Replace openclaw lib dir
  rm $out/lib/openclaw
  mkdir -p $out/lib/openclaw
  for item in $openclaw/lib/openclaw/*; do
    ln -s "$item" "$out/lib/openclaw/$(basename "$item")"
  done

  # Replace extensions with a real dir containing originals + custom plugins
  rm $out/lib/openclaw/extensions
  mkdir -p $out/lib/openclaw/extensions

  # Symlink all original bundled extensions
  for ext in $openclaw/lib/openclaw/extensions/*; do
    ln -s "$ext" "$out/lib/openclaw/extensions/$(basename "$ext")"
  done

  # Copy in custom plugins
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: path: ''
    cp -r ${path} $out/lib/openclaw/extensions/${name}
  '') pluginDirs)}
''
