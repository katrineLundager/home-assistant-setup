{ stdenv, python3, fetchFromGitHub }:

let
  python = python3.withPackages (ps: [ ps.websockets ]);
in
stdenv.mkDerivation rec {
  pname = "clickhouse-ingestor";
  version = "1.0.0";

  # Pinned to commit 3642fa3 (main branch as of 2025-10-03)
  src = fetchFromGitHub {
    owner = "apbodrov";
    repo = "clickhouse-hassio";
    rev = "3642fa32caa1701db84f3814f93936a67db14346";
    sha256 = "sha256-PhdH3tL9whPpw5aZGOqcyRAQ+cSeLnAK5aDk/Ekmays=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp ingestor/ingestor.py $out/lib/ingestor.py
    cat > $out/bin/clickhouse-ingestor <<EOF
    #!${python}/bin/python3
    import sys
    sys.path.insert(0, "$out/lib")
    exec(open("$out/lib/ingestor.py").read())
    EOF
    chmod +x $out/bin/clickhouse-ingestor
    runHook postInstall
  '';
}
