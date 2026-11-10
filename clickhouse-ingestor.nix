{ stdenv, python3 }:

let
  python = python3.withPackages (ps: [ ps.websockets ]);
in
stdenv.mkDerivation {
  pname = "clickhouse-ingestor";
  version = "1.0.0";

  # Local patched copy of upstream apbodrov/clickhouse-hassio @ 3642fa3
  # (ingestor/ingestor.py). Adds EXCLUDE_ATTRIBUTES_BY_ENTITY support.
  dontUnpack = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin $out/lib
    cp ${./ingestor.py} $out/lib/ingestor.py
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
