{ lib, stdenv, fetchurl, makeWrapper, jre_headless }:

stdenv.mkDerivation rec {
  pname = "opentripplanner";
  version = "2.8.1";

  src = fetchurl {
    url = "https://repo1.maven.org/maven2/org/opentripplanner/otp-shaded/${version}/otp-shaded-${version}.jar";
    sha256 = "sha256-jd1zbbaIRsXUB5fWKmp23eXZ5gdvI7cRMR+4xbAIJ0k=";
  };

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/otp $out/bin
    cp $src $out/share/otp/otp-shaded-${version}.jar
    makeWrapper ${jre_headless}/bin/java $out/bin/otp \
      --add-flags "-jar $out/share/otp/otp-shaded-${version}.jar"
    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenTripPlanner - multimodal trip planning engine";
    homepage = "https://www.opentripplanner.org/";
    license = licenses.lgpl3Plus;
    platforms = platforms.all;
    mainProgram = "otp";
  };
}
