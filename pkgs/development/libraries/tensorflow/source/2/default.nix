{ stdenv, pkgs, bazel, buildBazelPackage, lib, fetchFromGitHub, fetchpatch, symlinkJoin
, addOpenGLRunpath
, runCommand, lndir
# Python deps
, buildPythonPackage, isPy3k, isPy27, pythonOlder, pythonAtLeast, python
# Python libraries
, numpy, tensorflow-tensorboard_2, backports_weakref, mock, enum34, absl-py
, future, setuptools, wheel, keras-preprocessing, keras-applications, google-pasta
, functools32
, opt-einsum
, termcolor, grpcio, six, wrapt, protobuf, tensorflow-estimator_2
# Common deps
, git, swig, which, binutils, glibcLocales, cython
# Common libraries
, jemalloc, openmpi, astor, gast, grpc, sqlite, openssl, jsoncpp, re2
, curl, snappy, flatbuffers, icu, double-conversion, libpng, libjpeg_turbo, giflib
# Upsteam by default includes cuda support since tensorflow 1.15. We could do
# that in nix as well. It would make some things easier and less confusing, but
# it would also make the default tensorflow package unfree. See
# https://groups.google.com/a/tensorflow.org/forum/#!topic/developers/iRCt5m4qUz0
#, cudaSupport ? false, nvidia_x11 ? null, cudatoolkit ? null, cudnn ? null, nccl ? null
, mklSupport ? false, mkl ? null
# XLA without CUDA is broken
#, xlaSupport ? cudaSupport
# Default from ./configure script
#, cudaCapabilities ? [ "3.5" "5.2" ]
, sse42Support ? builtins.elem (stdenv.hostPlatform.platform.gcc.arch or "default") ["westmere" "sandybridge" "ivybridge" "haswell" "broadwell" "skylake" "skylake-avx512"]
, avx2Support  ? builtins.elem (stdenv.hostPlatform.platform.gcc.arch or "default") [                                     "haswell" "broadwell" "skylake" "skylake-avx512"]
, fmaSupport   ? builtins.elem (stdenv.hostPlatform.platform.gcc.arch or "default") [                                     "haswell" "broadwell" "skylake" "skylake-avx512"]
# Darwin deps
#, Foundation, Security
# ROCm
, config
, hip
, hipcub, hipsparse, miopen-hip, miopengemm
, rocrand, rocprim, rocfft, rocblas, rocr, rccl, roctracer, cxlactivitylogger
}:

#assert cudaSupport -> nvidia_x11 != null
#                   && cudatoolkit != null
#                   && cudnn != null;

# unsupported combination
#assert ! (stdenv.isDarwin && cudaSupport);

assert mklSupport -> mkl != null;

let
  #rocmtoolkit_joined = symlinkJoin {
  #  name = "unsplit_rocmtoolkit";
  #  paths = [ 
  #    hcc hcc-unwrapped
  #    hip hipcub miopen-hip miopengemm
  #    rocrand rocprim rocfft rocblas rocr rccl cxlactivitylogger 
  #  ];
  #};

  rocmtoolkit_joined = runCommand "unsplit_rocmtoolkit" {} ''
    mkdir -p $out 
    ln -s ${hip} $out/hip
    ln -s ${hipsparse} $out/hipsparse
    ln -s ${rocrand}/hiprand $out/hiprand
    ln -s ${rocfft} $out/rocfft
    ln -s ${rocblas} $out/rocblas
    ln -s ${miopen-hip} $out/miopen
    ln -s ${miopengemm} $out/miopengemm
    ln -s ${rccl} $out/rccl
    ln -s ${hipcub} $out/hipcub
    ln -s ${rocprim} $out/rocprim
    ln -s ${rocr} $out/hsa
    ln -s ${roctracer} $out/roctracer
    ln -s ${cxlactivitylogger} $out/cxlactivitylogger
    for i in ${hip} ${hipsparse} ${rocrand}/hiprand ${rocfft} ${rocblas} ${miopen-hip} ${miopengemm} ${rccl} ${hipcub} ${rocprim} ${rocr} ${roctracer} ${cxlactivitylogger} ${binutils.bintools}; do
      ${lndir}/bin/lndir -silent $i $out
    done
    ln -s ${rocrand}/hiprand/include $out/include/hiprand
  '';

  withTensorboard = pythonOlder "3.6";

  #cudatoolkit_joined = symlinkJoin {
  #  name = "${cudatoolkit.name}-merged";
  #  paths = [
  #    cudatoolkit.lib
  #    cudatoolkit.out
  #    # for some reason some of the required libs are in the targets/x86_64-linux
  #    # directory; not sure why but this works around it
  #    "${cudatoolkit}/targets/${stdenv.system}"
  #  ];
  #};

  #cudatoolkit_cc_joined = symlinkJoin {
  #  name = "${cudatoolkit.cc.name}-merged";
  #  paths = [
  #    cudatoolkit.cc
  #    binutils.bintools # for ar, dwp, nm, objcopy, objdump, strip
  #  ];
  #};

  # Needed for _some_ system libraries, grep INCLUDEDIR.
  includes_joined = symlinkJoin {
    name = "tensorflow-deps-merged";
    paths = [
      pkgs.protobuf
      jsoncpp
    ];
  };

  tfFeature = x: if x then "1" else "0";

  version = "760bec08ba01c374b44015493b975c6d52beb324"; #"2.2.0";
  variant = "-rocm";
  pname = "tensorflow${variant}";

  pythonEnv = python.withPackages (_:
    [ # python deps needed during wheel build time (not runtime, see the buildPythonPackage part for that)
      numpy
      keras-preprocessing
      protobuf
      wrapt
      gast
      astor
      absl-py
      termcolor
      keras-applications
      setuptools
      wheel
  ] ++ lib.optionals (!isPy3k)
  [ future
    functools32
    mock
  ]);

  bazel-build = buildBazelPackage {
    name = "${pname}-${version}";
    bazel = bazel; #bazel.overrideAttrs (oldAttrs: rec {version="2.0.0";}); #bazel_0_29;
    removeRulesCC = false;

    #src = fetchFromGitHub {
    #  owner = "ROCmSoftwarePlatform";
    #  repo = "tensorflow-upstream";
    #  rev = "${version}";
    #  sha256 = "1g79xi8yl4sjia8ysk9b7xfzrz83zy28v5dlb2wzmcf0k5pmz60p";
    #};

    src = fetchGit {
      url = "https://github.com/ROCmSoftwarePlatform/tensorflow-upstream";
      rev = "${version}";
    };

    patches = [
      # Work around https://github.com/tensorflow/tensorflow/issues/24752
      #../no-saved-proto.patch
      # Fixes for NixOS jsoncpp
      ../system-jsoncpp.patch
      # Account for Intel's rebranding 
      #../bazel_workspace.patch
      #../protobuf_repo.patch
      ../rocm_follow_symlinks.patch

      #(fetchpatch {
      #  name = "backport-pr-18950.patch";
      #  url = "https://github.com/tensorflow/tensorflow/commit/73640aaec2ab0234d9fff138e3c9833695570c0a.patch";
      #  sha256 = "1n9ypbrx36fc1kc9cz5b3p9qhg15xxhq4nz6ap3hwqba535nakfz";
      #})

      #(fetchpatch {
      #  # Don't try to fetch things that don't exist
      #  name = "prune-missing-deps.patch";
      #  url = "https://github.com/tensorflow/tensorflow/commit/b39b1ed24b4814db27d2f748dc85c10730ae851d.patch";
      #  sha256 = "1skysz53nancvw1slij6s7flar2kv3gngnsq60ff4lap88kx5s6c";
      #  excludes = [ "tensorflow/cc/saved_model/BUILD" ];
      #})

      #./lift-gast-restriction.patch

      # cuda 10.2 does not have "-bin2c-path" option anymore
      # https://github.com/tensorflow/tensorflow/issues/34429
      #../cuda-10.2-no-bin2c-path.patch
    ];

    # On update, it can be useful to steal the changes from gentoo
    # https://gitweb.gentoo.org/repo/gentoo.git/tree/sci-libs/tensorflow

    nativeBuildInputs = [
      swig which pythonEnv
      addOpenGLRunpath
    ];

    buildInputs = [
      jemalloc
      openmpi
      glibcLocales
      git

      # libs taken from system through the TF_SYS_LIBS mechanism
      # grpc
      sqlite
      openssl
      jsoncpp
      pkgs.protobuf
      curl
      snappy
      flatbuffers
      icu
      double-conversion
      libpng
      libjpeg_turbo
      giflib
      re2
      pkgs.lmdb

      #ROCm
      hip 
      hipcub hipsparse miopen-hip miopengemm
      rocrand rocprim rocfft rocblas rocr rccl roctracer cxlactivitylogger
    #] ++ lib.optionals cudaSupport [
    #  cudatoolkit
    #  cudnn
    #  nvidia_x11
    ] ++ lib.optionals mklSupport [
      mkl
    #] ++ lib.optionals stdenv.isDarwin [
    #  Foundation
    #  Security
    ];

    # arbitrarily set to the current latest bazel version, overly careful
    TF_IGNORE_MAX_BAZEL_VERSION = true;

    # Take as many libraries from the system as possible. Keep in sync with
    # list of valid syslibs in
    # https://github.com/tensorflow/tensorflow/blob/master/third_party/systemlibs/syslibs_configure.bzl
    TF_SYSTEM_LIBS = lib.concatStringsSep "," [
      "absl_py"
      "astor_archive"
      "boringssl"
    #  # Not packaged in nixpkgs
    #  # "com_github_googleapis_googleapis"
    #  # "com_github_googlecloudplatform_google_cloud_cpp"
      "com_google_protobuf"
      "com_googlesource_code_re2"
      "curl"
      "cython"
      "double_conversion"
      "flatbuffers"
      "gast_archive"
    #  # Lots of errors, requires an older version
    #  # "grpc"
      "hwloc"
      "icu"
      "libjpeg_turbo"
      "jsoncpp_git"
      "lmdb"
      "nasm"
    #  # "nsync" # not packaged in nixpkgs
      "opt_einsum_archive"
      "org_sqlite"
      "pasta"
      "pcre"
      "six_archive"
      "snappy"
      "swig"
      "termcolor_archive"
      "wrapt"
    #  "zlib_archive"
    ];

    INCLUDEDIR = "${includes_joined}/include";

    PYTHON_BIN_PATH = pythonEnv.interpreter;

    TF_NEED_GCP = true;
    TF_NEED_HDFS = true;
    #TF_ENABLE_XLA = 0; #tfFeature xlaSupport;
    #USE_MKLDNN = tfFeature mklSupport;
    #TENSORFLOW_USE_MKLDNN_CONTRACTION_KERNEL = tfFeature mklSupport;

    CC_OPT_FLAGS = " ";

    # https://github.com/tensorflow/tensorflow/issues/14454
    #TF_NEED_MPI = tfFeature cudaSupport;

    #TF_NEED_CUDA = tfFeature cudaSupport;
    #TF_CUDA_PATHS = lib.optionalString cudaSupport "${cudatoolkit_joined},${cudnn},${nccl}";
    #LLVM_HOST_COMPILER_PREFIX = "${binutils}/bin";
    #LLVM_HOST_COMPILER_PATH = "${binutils}/bin/gcc";
    #LLVM_BINUTILS_INCDIR="${stdenv.lib.getDev binutils}/include";
    #TF_CUDA_COMPUTE_CAPABILITIES = lib.concatStringsSep "," cudaCapabilities;

    TF_NEED_ROCM = 1;
    ROCM_PATH = "${rocmtoolkit_joined}";
    TF_ROCM_VERSION = "3.5.0";
    #TF_MIOPEN_VERSION = "${miopen.version}";
    ROCM_TOOLKIT_PATH = "${rocmtoolkit_joined}";
    TF_ROCM_AMDGPU_TARGETS = "${lib.strings.concatStringsSep "," (config.rocmTargets or ["gfx803" "gfx900" "gfx906"])}";
    GCC_HOST_COMPILER_PREFIX = "${rocmtoolkit_joined}/bin";

    postPatch = ''
      # https://github.com/tensorflow/tensorflow/issues/20919
      sed -i '/androidndk/d' tensorflow/lite/kernels/internal/BUILD
      # Tensorboard pulls in a bunch of dependencies, some of which may
      # include security vulnerabilities. So we make it optional.
      # https://github.com/tensorflow/tensorflow/issues/20280#issuecomment-400230560
      sed -i '/tensorboard >=/d' tensorflow/tools/pip_package/setup.py
      # it appears this is no longer needed
      #sed -e 's|/opt/rocm|${rocmtoolkit_joined}|' -i ./third_party/gpus/rocm_configure.bzl
      # hack to include all hcc compiler bits 
      #printf -v allpossibledirs '%s\n' "$(dirname $(find -L ${rocmtoolkit_joined} -type f,l -exec realpath {} \;))" "$(find -L /nix/store -wholename '*hcc-clang-unwrapped-wrapper*' -type d)"
      printf -v allpossibledirs '%s\n' "$(dirname $(find -L ${rocmtoolkit_joined} -type f,l -exec realpath {} \;))"
      sed -e "s|nixos sed target|[ \"$(echo "$allpossibledirs" | sort -u | sed ':a;N;$!ba;s/\n/", "/g')\" ]|" -i ./third_party/gpus/rocm_configure.bzl
      #echo "$(echo "$allpossibledirs" | sort -u)"
      echo ${bazel.version}
      rm .bazelversion
      echo ${bazel.version} > .bazelversion
      #bazel --batch --bazelrc=/dev/null version
      bazel clean --expunge
    '';

    preConfigure = let
      opt_flags = []
        ++ lib.optionals sse42Support ["-msse4.2"]
        ++ lib.optionals avx2Support ["-mavx2"]
        ++ lib.optionals fmaSupport ["-mfma"];
    in ''
      patchShebangs configure
      # dummy ldconfig
      mkdir dummy-ldconfig
      echo "#!${stdenv.shell}" > dummy-ldconfig/ldconfig
      chmod +x dummy-ldconfig/ldconfig
      export PATH="$PWD/dummy-ldconfig:$PATH"
      export PYTHON_LIB_PATH="$NIX_BUILD_TOP/site-packages"
      export CC_OPT_FLAGS="${lib.concatStringsSep " " opt_flags}"
      mkdir -p "$PYTHON_LIB_PATH"
      # To avoid mixing Python 2 and Python 3
      unset PYTHONPATH
    '';

    configurePhase = ''
      runHook preConfigure
      ./configure
      runHook postConfigure
    '';

    # FIXME: Tensorflow uses dlopen() for CUDA libraries.
    #NIX_LDFLAGS = "-lmcwamp";

    hardeningDisable = [ "format" ];

    bazelFlags = [
      # temporary fixes to make the build work with bazel 0.27
      #"--incompatible_no_support_tools_in_action_inputs=false"
      #"--keep_going=true"
    ];
    bazelBuildFlags = [
      "--config=v2"
      "--config=opt" # optimize using the flags set in the configure phase
      #"--cxxopt=-std=c++11"
      "--config=rocm"
      #"--define=tensorflow_mkldnn_contraction_kernel=0"
    ]
    ++ lib.optionals (mklSupport) [ "--config=mkl" ];

    bazelTarget = "//tensorflow/tools/pip_package:build_pip_package //tensorflow/tools/lib_package:libtensorflow";
 
    fetchAttrs = {
      # So that checksums don't depend on these.
      TF_SYSTEM_LIBS = null;

      buildPhase = ''
        runHook preBuild
        copts=()
        host_copts=()
        for flag in $NIX_CFLAGS_COMPILE; do
          copts+=( "--copt=$flag" )
          host_copts+=( "--host_copt=$flag" )
        done
        for flag in $NIX_CXXSTDLIB_COMPILE; do
          copts+=( "--copt=$flag" )
          host_copts+=( "--host_copt=$flag" )
        done
        linkopts=()
        host_linkopts=()
        for flag in $NIX_LDFLAGS; do
          linkopts+=( "--linkopt=-Wl,$flag" )
          host_linkopts+=( "--host_linkopt=-Wl,$flag" )
        done
        # Bazel computes the default value of output_user_root before parsing the
        # flag. The computation of the default value involves getting the $USER
        # from the environment. I don't have that variable when building with
        # sandbox enabled. Code here
        # https://github.com/bazelbuild/bazel/blob/9323c57607d37f9c949b60e293b573584906da46/src/main/cpp/startup_options.cc#L123-L124
        #
        # On macOS Bazel will use the system installed Xcode or CLT toolchain instead of the one in the PATH unless we pass BAZEL_USE_CPP_ONLY_TOOLCHAIN
        # We disable multithreading for the fetching phase since it can lead to timeouts with many dependencies/threads:
        # https://github.com/bazelbuild/bazel/issues/6502
        BAZEL_USE_CPP_ONLY_TOOLCHAIN=1 \
        USER=homeless-shelter \
        bazel \
          --output_base="$bazelOut" \
          --output_user_root="$bazelUserRoot" \
          build --build=false \
          --loading_phase_threads=1 \
          "''${copts[@]}" \
          "''${host_copts[@]}" \
          "''${linkopts[@]}" \
          "''${host_linkopts[@]}" \
          $bazelFlags \
          $bazelFetchFlags \
          $bazelTarget
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        # Remove all built in external workspaces, Bazel will recreate them when building
        #rm -rf $bazelOut/external/{bazel_tools,\@bazel_tools.marker}
        #{if removeRulesCC then "rm -rf $bazelOut/external/{rules_cc,\\@rules_cc.marker}" else ""}
        #rm -rf $bazelOut/external/{embedded_jdk,\@embedded_jdk.marker}
        #{if removeLocalConfigCc then "rm -rf $bazelOut/external/{local_config_cc,\@local_config_cc.marker}" else ""}
        #rm -rf $bazelOut/external/{local_config_cc,\@local_config_cc.marker}
        #{if removeLocal then "rm -rf $bazelOut/external/{local_*,\@local_*.marker}" else ""}
        #rm -rf $bazelOut/external/{local_*,\@local_*.marker}
        # Clear markers
        find $bazelOut/external -name '@*\.marker' -exec sh -c 'echo > {}' \;
        # Remove all vcs files
        rm -rf $(find $bazelOut/external -type d -name .git)
        rm -rf $(find $bazelOut/external -type d -name .svn)
        rm -rf $(find $bazelOut/external -type d -name .hg)
        # Removing top-level symlinks along with their markers.
        # This is needed because they sometimes point to temporary paths (?).
        # For example, in Tensorflow-gpu build:
        # platforms -> NIX_BUILD_TOP/tmp/install/35282f5123611afa742331368e9ae529/_embedded_binaries/platforms
        find $bazelOut/external -maxdepth 1 -type l | while read symlink; do
          name="$(basename "$symlink")"
          rm "$symlink" "$bazelOut/external/@$name.marker"
        done
        # Patching symlinks to remove build directory reference
        find $bazelOut/external -type l | while read symlink; do
          new_target="$(readlink "$symlink" | sed "s,$NIX_BUILD_TOP,NIX_BUILD_TOP,")"
          rm "$symlink"
          ln -sf "$new_target" "$symlink"
        done
        echo '${bazel.name}' > $bazelOut/external/.nix-bazel-version
        (cd $bazelOut/ && tar czf $out --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner external/)
        runHook postInstall
      '';

      # Don't use sytem libs so this remains constant
      sha256 = "0kizmfvpyi8g01kjsh84p99h46pg0nrcsfzd3f87642d6nrphapk";
    };

    buildAttrs = {
      outputs = [ "out" "python" ];

      preBuild = ''
        patchShebangs .
      '';

      installPhase = ''
        mkdir -p "$out"
        tar -xf bazel-bin/tensorflow/tools/lib_package/libtensorflow.tar.gz -C "$out"
        # Write pkgconfig file.
        mkdir "$out/lib/pkgconfig"
        cat > "$out/lib/pkgconfig/tensorflow.pc" << EOF
        Name: TensorFlow
        Version: ${version}
        Description: Library for computation using data flow graphs for scalable machine learning
        Requires:
        Libs: -L$out/lib -ltensorflow
        Cflags: -I$out/include/tensorflow
        EOF
        # build the source code, then copy it to $python (build_pip_package
        # actually builds a symlink farm so we must dereference them).
        bazel-bin/tensorflow/tools/pip_package/build_pip_package --src "$PWD/dist"
        cp -Lr "$PWD/dist" "$python"
      '';

      #TODO determine if this is needed for ROCm
      postFixup = ''
        find $out -type f \( -name '*.so' -or -name '*.so.*' \) | while read lib; do
          addOpenGLRunpath "$lib"
        done
      '';
    };

    meta = with stdenv.lib; {
      description = "Computation using data flow graphs for scalable machine learning";
      homepage = "http://tensorflow.org";
      license = licenses.asl20;
      maintainers = with maintainers; [ jyp abbradar wulfsta ];
      platforms = with platforms; linux;
      # The py2 build fails due to some issue importing protobuf. Possibly related to the fix in
      # https://github.com/akesandgren/easybuild-easyblocks/commit/1f2e517ddfd1b00a342c6abb55aef3fd93671a2b
      broken = !isPy3k;
    };
  };

in buildPythonPackage {
  inherit version pname;
  disabled = isPy27 || (pythonAtLeast "3.8");

  src = bazel-build.python;

  # Upstream has a pip hack that results in bin/tensorboard being in both tensorflow
  # and the propagated input tensorflow-tensorboard, which causes environment collisions.
  # Another possibility would be to have tensorboard only in the buildInputs
  # https://github.com/tensorflow/tensorflow/blob/v1.7.1/tensorflow/tools/pip_package/setup.py#L79
  postInstall = ''
    rm $out/bin/tensorboard
  '';

  setupPyGlobalFlags = [ "--project_name ${pname}" ];

  # tensorflow/tools/pip_package/setup.py
  propagatedBuildInputs = [
    absl-py
    astor
    gast
    google-pasta
    keras-applications
    keras-preprocessing
    numpy
    six
    protobuf
    tensorflow-estimator_2
    termcolor
    wrapt
    grpcio
    opt-einsum
  ] ++ lib.optionals (!isPy3k) [
    mock
    future
    functools32
  ] ++ lib.optionals (pythonOlder "3.4") [
    backports_weakref enum34
  ] ++ lib.optionals withTensorboard [
    tensorflow-tensorboard_2
  ];

  nativeBuildInputs = [ addOpenGLRunpath ];

  #TODO determine if this is needed for ROCm
  postFixup = ''
    find $out -type f \( -name '*.so' -or -name '*.so.*' \) | while read lib; do
      addOpenGLRunpath "$lib"
    done
  '';

  # Actual tests are slow and impure.
  # TODO try to run them anyway
  # TODO better test (files in tensorflow/tools/ci_build/builds/*test)
  checkPhase = ''
  #  ${python.interpreter} <<EOF
  #  # A simple "Hello world"
  #  import tensorflow as tf
  #  hello = tf.constant("Hello, world!")
  #  tf.print(hello)
  #  # Fit a simple model to random data
  #  import numpy as np
  #  np.random.seed(0)
  #  tf.random.set_seed(0)
  #  model = tf.keras.models.Sequential([
  #      tf.keras.layers.Dense(1, activation="linear")
  #  ])
  #  model.compile(optimizer="sgd", loss="mse")
  #  x = np.random.uniform(size=(1,1))
  #  y = np.random.uniform(size=(1,))
  #  model.fit(x, y, epochs=1)
  #  EOF
  '';
  # Regression test for #77626 removed because not more `tensorflow.contrib`.

  passthru.libtensorflow = bazel-build.out;

  inherit (bazel-build) meta;
}
