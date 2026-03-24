# Vendored from nixpkgs pkgs/by-name/op/openclaw/package.nix
# Fixes for sandboxed aarch64-linux builds:
#
# 1. COREPACK_ENABLE_NETWORK=0 — pnpm-config-hook.sh runs `pnpm --version`
#    before setting `manage-package-manager-versions false`. Corepack intercepts
#    this and tries to fetch the exact pnpm version from registry.npmjs.org,
#    which fails inside the nix sandbox. Setting COREPACK_ENABLE_NETWORK=0
#    prevents any corepack network calls.
#
# 2. buildPhase uses --offline — upstream runs `pnpm install --frozen-lockfile`
#    without --offline after pnpmConfigHook already ran the offline install.
#    Changed to --offline so it uses the pre-fetched store unconditionally.
{
  lib,
  stdenvNoCC,
  buildPackages,
  fetchFromGitHub,
  fetchPnpmDeps,
  pnpmConfigHook,
  pnpm_10,
  nodejs_22,
  makeWrapper,
  rolldown,
  installShellFiles,
  version ? "2026.3.12",
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "openclaw";
  version = version;

  src = fetchFromGitHub {
    owner = "openclaw";
    repo = "openclaw";
    tag = "v${finalAttrs.version}";
    hash = "sha256-dGKfXkC7vHflGbg+SkgSMfM5LW8w1YQIWicgp3BKDQ8=";
  };

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs) pname version src;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-GHTkpwOj2Y29YUcS/kbZlCdo9DL8C3WW3WHe0PMIN/M=";
  };

  buildInputs = [ rolldown ];

  nativeBuildInputs = [
    pnpmConfigHook
    pnpm_10
    nodejs_22
    makeWrapper
    installShellFiles
  ];

  # Fix 1: disable corepack network access before any hook runs
  env.COREPACK_ENABLE_NETWORK = "0";

  preBuild = ''
    rm -rf node_modules/rolldown node_modules/@rolldown/pluginutils
    mkdir -p node_modules/@rolldown
    cp -r ${rolldown}/lib/node_modules/rolldown node_modules/rolldown
    cp -r ${rolldown}/lib/node_modules/@rolldown/pluginutils node_modules/@rolldown/pluginutils
    chmod -R u+w node_modules/rolldown node_modules/@rolldown/pluginutils
  '';

  buildPhase = ''
    runHook preBuild

    # Fix 2: use --offline so pnpm doesn't attempt registry access
    pnpm install --offline --frozen-lockfile
    pnpm build
    pnpm ui:build

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    libdir=$out/lib/openclaw
    mkdir -p $libdir $out/bin

    cp --reflink=auto -r package.json dist node_modules $libdir/
    cp --reflink=auto -r assets docs skills patches extensions $libdir/ 2>/dev/null || true

    rm -f $libdir/node_modules/.pnpm/node_modules/clawdbot \
      $libdir/node_modules/.pnpm/node_modules/moltbot \
      $libdir/node_modules/.pnpm/node_modules/openclaw-control-ui

    makeWrapper ${lib.getExe nodejs_22} $out/bin/openclaw \
      --add-flags "$libdir/dist/index.js" \
      --set NODE_PATH "$libdir/node_modules"
    ln -s $out/bin/openclaw $out/bin/moltbot
    ln -s $out/bin/openclaw $out/bin/clawdbot

    runHook postInstall
  '';

  postInstall = lib.optionalString (stdenvNoCC.hostPlatform.emulatorAvailable buildPackages) (
    let
      emulator = stdenvNoCC.hostPlatform.emulator buildPackages;
    in
    ''
      installShellCompletion --cmd openclaw \
        --bash <(${emulator} $out/bin/openclaw completion --shell bash) \
        --fish <(${emulator} $out/bin/openclaw completion --shell fish) \
        --zsh <(${emulator} $out/bin/openclaw completion --shell zsh)
    ''
  );

  meta = {
    description = "Self-hosted, open-source AI assistant/agent";
    homepage = "https://openclaw.ai";
    license = lib.licenses.mit;
    mainProgram = "openclaw";
    platforms = with lib.platforms; linux ++ darwin;
  };
})
