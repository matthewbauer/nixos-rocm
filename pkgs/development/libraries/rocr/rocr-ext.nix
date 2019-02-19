# AMD has not released the source code for image object support for
# their GPUs. This functionality is available in their binary-only
# releases in the `hsa-ext-rocr-dev` deb package. We unpack the
# compiled libraries from that package here, and set an environment
# variable (`ROCR_EXT_DIR`)to this derivation's `lib` directory. The
# `rocr` runtime uses that environment variable when trying to load
# extension libraries, so that downstream rocr consumers like the
# OpenCL runtime can take advantage of the extension libraries if this
# package is a also a dependency of your derivation.
{ stdenv, fetchurl, writeText, dpkg }:
stdenv.mkDerivation rec {
  version = "2.1.0";
  name = "rocr-ext-${version}";
  src = fetchurl {
    url = "http://repo.radeon.com/rocm/apt/debian/pool/main/h/hsa-ext-rocr-dev/hsa-ext-rocr-dev_1.1.9-49-g39f1af5_amd64.deb";
    sha256 = "044r321ib1y18r40r8p345g8b4cki7rfr112i5pdqd094x8siv9f";
  };
  builder = writeText "builder.sh" ''
    source $stdenv/setup
    ${dpkg}/bin/dpkg-deb -R $src tmp
    cp -R tmp/opt/rocm/hsa/ $out
    mkdir -p $out/nix-support
    echo "export ROCR_EXT_DIR=$out/lib" > $out/nix-support/setup-hook
  '';
  meta = {
    description = "Closed-source runtime extension package";
    homepage = https://github.com/RadeonOpenCompute/ROCR-Runtime;
    license = stdenv.lib.licenses.unfreeRedistributable;
  };
}
