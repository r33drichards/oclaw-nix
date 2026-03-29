# Wraps an OpenClaw package with additional bundled plugins.
# Plugins are symlinked into the extensions directory so they're
# discovered automatically at startup (as bundled extensions).
{ lib, symlinkJoin, openclaw }:

let
  # Each subdirectory here is a plugin (must contain openclaw.plugin.json + index.ts)
  pluginDirs = {
    exa-search = ./exa-search;
  };
in
symlinkJoin {
  name = "openclaw-with-plugins-${openclaw.version}";
  paths = [ openclaw ];

  # After symlinkJoin creates the merged tree, copy in our plugins.
  # We need to replace the extensions symlink with a real directory
  # that contains both the original extensions and our new ones.
  postBuild = ''
    # The extensions dir is a symlink to the nix store — replace with a real dir
    rm $out/lib/openclaw/extensions
    mkdir -p $out/lib/openclaw/extensions

    # Re-link all original bundled extensions
    for ext in ${openclaw}/lib/openclaw/extensions/*; do
      ln -s "$ext" "$out/lib/openclaw/extensions/$(basename "$ext")"
    done

    # Add our custom plugins
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: path: ''
      cp -r ${path} $out/lib/openclaw/extensions/${name}
    '') pluginDirs)}
  '';

  meta = openclaw.meta // {
    description = "${openclaw.meta.description or "OpenClaw"} (with custom plugins)";
  };
}
