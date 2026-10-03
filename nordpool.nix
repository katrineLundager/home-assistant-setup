{ buildHomeAssistantComponent, fetchFromGitHub, pkgs}:

buildHomeAssistantComponent rec {
  owner = "custom-components";
  domain = "nordpool";
  version = "0.0.18";

  src = fetchFromGitHub {
    owner = "custom-components";
    repo = "nordpool";
    rev = version;
    sha256 = "sha256-ESyTWibeH3R98doY44r+OVw5f9kWlPKNL5LSP4Mifew=";
  };
    propagatedBuildInputs = [
      pkgs.python314Packages.backoff
    ];
}
