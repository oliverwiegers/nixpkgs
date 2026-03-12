{
  fetchurl,
  lib,
  stdenv,
  poweradmin,
  nixosTests,
}:

stdenv.mkDerivation rec {
  pname = "poweradmin";
  version = "4.1.1";

  src = fetchurl {
    url = "https://github.com/poweradmin/poweradmin/releases/download/v${version}/v${version}.tar.gz";
    sha256 = "$put_correct_sha_here";
  };

  dontBuild = true;

  # FIXME: this should be removed after upstream releases the update forcing the use of public_html.
  # dontCheckForBrokenSymlinks = true;

  installPhase = ''
    mkdir $out
    cp -r * $out/
    ln -sf /etc/poweradmin/setttings.php $out/config/setttings.php
    rm -rf $out/installer
    # shut up updater
    rm $out/composer.json-dist
  '';

  passthru.tests = { inherit (nixosTests) poweradmin; };

  meta = {
    description = "Web-based control panel for PowerDNS";
    maintainers = with lib.maintainers; [
      kubicgruenfeld
      oliverwiegers
    ];
    license = lib.licenses.gpl3;
    platforms = lib.platforms.all;
  };
}
