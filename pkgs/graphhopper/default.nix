{ lib, stdenv, fetchurl, makeWrapper, jre_headless }:

stdenv.mkDerivation rec {
  pname = "graphhopper";
  version = "11.0";

  src = fetchurl {
    url = "https://repo1.maven.org/maven2/com/graphhopper/graphhopper-web/${version}/graphhopper-web-${version}.jar";
    sha256 = "b59c024afe172ec6ec85b6327006c3138ec58c7d0bcd26253d0e42853f613def";
  };

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/graphhopper $out/bin
    cp $src $out/share/graphhopper/graphhopper-web-${version}.jar
    makeWrapper ${jre_headless}/bin/java $out/bin/graphhopper \
      --add-flags "-Xmx2g -Xms1g" \
      --add-flags "-jar $out/share/graphhopper/graphhopper-web-${version}.jar" \
      --add-flags "server"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Open source routing engine for OpenStreetMap";
    homepage = "https://github.com/graphhopper/graphhopper";
    license = licenses.asl20;
    platforms = platforms.all;
    mainProgram = "graphhopper";
  };
}
