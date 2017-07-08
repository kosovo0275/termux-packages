#!/bin/bash -x

set -e -o pipefail -u

# Utility function to log an error message and exit with an error code.
termux_error_exit() {
	echo "ERROR: $*" 1>&2
	exit 1
}

# Utility function to download a resource, optionally checking against a checksum.
termux_download() {
	local URL="$1"
	local DESTINATION="$2"

	if [ -f "$DESTINATION" ] && [ $# = 3 ] && [ -n "$3" ]; then
		# Keep existing file if checksum matches.
		local EXISTING_CHECKSUM
		EXISTING_CHECKSUM=$(sha256sum "$DESTINATION" | cut -f 1 -d ' ')
		if [ "$EXISTING_CHECKSUM" = "$3" ]; then return; fi
	fi

	local TMPFILE
	TMPFILE=$(mktemp "$TERMUX_PKG_TMPDIR/download.$TERMUX_PKG_NAME.XXXXXXXXX")
	echo "Downloading ${URL}"
	local TRYMAX=6
	for try in $(seq 1 $TRYMAX); do
		if curl -L --fail --retry 2 -o "$TMPFILE" "$URL"; then
			local ACTUAL_CHECKSUM
			ACTUAL_CHECKSUM=$(sha256sum "$TMPFILE" | cut -f 1 -d ' ')
			if [ $# = 3 ] && [ -n "$3" ]; then
				# Optional checksum argument:
				local EXPECTED=$3
				if [ "$EXPECTED" != "$ACTUAL_CHECKSUM" ]; then
					>&2 printf "Wrong checksum for %s:\nExpected: %s\nActual:   %s\n" \
					           "$URL" "$EXPECTED" "$ACTUAL_CHECKSUM"
					exit 1
				fi
			else
				printf "No validation of checksum for %s:\nActual: %s\n" \
				       "$URL" "$ACTUAL_CHECKSUM"
			fi
			mv "$TMPFILE" "$DESTINATION"
			return
		else
			echo "Download of $URL failed (attempt $try/$TRYMAX)" 1>&2
			sleep 45
		fi
	done

	termux_error_exit "Failed to download $URL"
}

# Utility function for golang-using packages to setup a go toolchain.
termux_setup_golang() {
	export GOOS=android
	export CGO_ENABLED=1
	export GO_LDFLAGS="-extldflags=-pie"
	export GOARCH=arm64

	local TERMUX_GO_VERSION=go1.8.3
	local TERMUX_GO_PLATFORM=linux-amd64

	local TERMUX_BUILDGO_FOLDER=$TERMUX_COMMON_CACHEDIR/${TERMUX_GO_VERSION}
	export GOROOT=$TERMUX_BUILDGO_FOLDER
	export PATH=$GOROOT/bin:$PATH

	if [ -d "$TERMUX_BUILDGO_FOLDER" ]; then return; fi

	local TERMUX_BUILDGO_TAR=$TERMUX_COMMON_CACHEDIR/${TERMUX_GO_VERSION}.${TERMUX_GO_PLATFORM}.tar.gz
	rm -Rf "$TERMUX_COMMON_CACHEDIR/go" "$TERMUX_BUILDGO_FOLDER"
	termux_download https://storage.googleapis.com/golang/${TERMUX_GO_VERSION}.${TERMUX_GO_PLATFORM}.tar.gz \
	                "$TERMUX_BUILDGO_TAR" \
	                1862f4c3d3907e59b04a757cfda0ea7aa9ef39274af99a784f5be843c80c6772

	( cd "$TERMUX_COMMON_CACHEDIR"; tar xf "$TERMUX_BUILDGO_TAR"; mv go "$TERMUX_BUILDGO_FOLDER"; rm "$TERMUX_BUILDGO_TAR" )
}

# Utility function for cmake-built packages to setup a current cmake.
termux_setup_cmake() {
	local TERMUX_CMAKE_MAJORVESION=3.8
	local TERMUX_CMAKE_MINORVERSION=2
	local TERMUX_CMAKE_VERSION=$TERMUX_CMAKE_MAJORVESION.$TERMUX_CMAKE_MINORVERSION
	local TERMUX_CMAKE_TARNAME=cmake-${TERMUX_CMAKE_VERSION}-Linux-x86_64.tar.gz
	local TERMUX_CMAKE_TARFILE=$TERMUX_PKG_TMPDIR/$TERMUX_CMAKE_TARNAME
	local TERMUX_CMAKE_FOLDER=$TERMUX_COMMON_CACHEDIR/cmake-$TERMUX_CMAKE_VERSION
	if [ ! -d "$TERMUX_CMAKE_FOLDER" ]; then
		termux_download https://cmake.org/files/v$TERMUX_CMAKE_MAJORVESION/$TERMUX_CMAKE_TARNAME \
		                "$TERMUX_CMAKE_TARFILE" \
		                33e4851d3219b720f4b64fcf617151168f1bffdf5afad25eb4b7f5f58cee3a08
		rm -Rf "$TERMUX_PKG_TMPDIR/cmake-${TERMUX_CMAKE_VERSION}-Linux-x86_64"
		tar xf "$TERMUX_CMAKE_TARFILE" -C "$TERMUX_PKG_TMPDIR"
		mv "$TERMUX_PKG_TMPDIR/cmake-${TERMUX_CMAKE_VERSION}-Linux-x86_64" \
		   "$TERMUX_CMAKE_FOLDER"
	fi
	export PATH=$TERMUX_CMAKE_FOLDER/bin:$PATH
	export CMAKE_INSTALL_ALWAYS=1
}

# First step is to handle command-line arguments. Not to be overridden by packages.
termux_step_handle_arguments() {
	# shellcheck source=/dev/null
	test -f "$HOME/.termuxrc" && source "$HOME/.termuxrc"

	# Handle command-line arguments:
	_show_usage () {
	    echo "Usage: ./build-package.sh [-a ARCH] [-d] [-D] PACKAGE"
	    echo "Build a package by creating a .deb file in the debs/ folder."
	    echo "  -a The architecture to build for: aarch64(default), arm, i686, x86_64 or all."
	    echo "  -d Build with debug symbols."
	    echo "  -D Build a disabled package in disabled-packages/."
	    echo "  -f Force build even if package has already been built."
	    echo "  -s Skip dependency check."
	    exit 1
	}
	while getopts :a:hdDfs option; do
		case "$option" in
		a) TERMUX_ARCH="$OPTARG";;
		h) _show_usage;;
		d) TERMUX_DEBUG=true;;
		D) local TERMUX_IS_DISABLED=true;;
		f) TERMUX_FORCE_BUILD=true;;
		s) export TERMUX_SKIP_DEPCHECK=true;;
		?) termux_error_exit "./build-package.sh: illegal option -$OPTARG";;
		esac
	done
	shift $((OPTIND-1))

	if [ "$#" -ne 1 ]; then _show_usage; fi
	unset -f _show_usage

	# Handle 'all' arch:
	if [ -n "${TERMUX_ARCH+x}" ] && [ "${TERMUX_ARCH}" = 'all' ]; then
		for arch in 'aarch64' 'arm' 'i686' 'x86_64'; do
			./build-package.sh ${TERMUX_FORCE_BUILD+-f} -a $arch "$1"
		done
		exit
	fi

	# Check the package to build:
	TERMUX_PKG_NAME=$(basename "$1")
	export TERMUX_SCRIPTDIR
	TERMUX_SCRIPTDIR=$(cd "$(dirname "$0")"; pwd)
	if [[ $1 == *"/"* ]]; then
		# Path to directory which may be outside this repo:
		if [ ! -d "$1" ]; then termux_error_exit "'$1' seems to be a path but is not a directory"; fi
		export TERMUX_PKG_BUILDER_DIR
		TERMUX_PKG_BUILDER_DIR=$(realpath "$1")
		# Skip depcheck for external package:
		TERMUX_SKIP_DEPCHECK=true
	else
		# Package name:
		if [ -n "${TERMUX_IS_DISABLED=""}" ]; then
			export TERMUX_PKG_BUILDER_DIR=$TERMUX_SCRIPTDIR/disabled-packages/$TERMUX_PKG_NAME
		else
			export TERMUX_PKG_BUILDER_DIR=$TERMUX_SCRIPTDIR/packages/$TERMUX_PKG_NAME
		fi
	fi
	TERMUX_PKG_BUILDER_SCRIPT=$TERMUX_PKG_BUILDER_DIR/build.sh
	if test ! -f "$TERMUX_PKG_BUILDER_SCRIPT"; then
		termux_error_exit "No build.sh script at package dir $TERMUX_PKG_BUILDER_DIR!"
	fi
}

# Setup variables used by the build. Not to be overridden by packages.
termux_step_setup_variables() {
	: "${ANDROID_HOME:="${HOME}/lib/android-sdk"}"
	: "${NDK:="${HOME}/lib/android-ndk"}"
	: "${TERMUX_MAKE_PROCESSES:="$(nproc)"}"
	: "${TERMUX_TOPDIR:="$HOME/.termux-build"}"
	: "${TERMUX_ARCH:="aarch64"}" # arm, aarch64, i686 or x86_64.
	: "${TERMUX_PREFIX:="/data/data/com.termux/files/usr"}"
	: "${TERMUX_ANDROID_HOME:="/data/data/com.termux/files/home"}"
	: "${TERMUX_DEBUG:="true"}"
	: "${TERMUX_API_LEVEL:="21"}"
	: "${TERMUX_ANDROID_BUILD_TOOLS_VERSION:="25.0.3"}"
	: "${TERMUX_NDK_VERSION:="15.1"}"
	: "${TERMUX_ARCH_BITS:="64"}"
	: "${TERMUX_HOST_PLATFORM:="aarch64-linux-android"}"

	if [ ! -d "$NDK" ]; then
		termux_error_exit 'NDK not pointing at a directory!'
	fi
	if ! grep -s -q "Pkg.Revision = $TERMUX_NDK_VERSION" "$NDK/source.properties"; then
		termux_error_exit "Wrong NDK version - we need $TERMUX_NDK_VERSION"
	fi

	# The build tuple that may be given to --build configure flag:
	TERMUX_BUILD_TUPLE=$(sh "$TERMUX_SCRIPTDIR/scripts/config.guess")

	# We do not put all of build-tools/$TERMUX_ANDROID_BUILD_TOOLS_VERSION/ into PATH
	# to avoid stuff like arm-linux-androideabi-ld there to conflict with ones from
	# the standalone toolchain.
	TERMUX_DX=$ANDROID_HOME/build-tools/$TERMUX_ANDROID_BUILD_TOOLS_VERSION/dx
	TERMUX_JACK=$ANDROID_HOME/build-tools/$TERMUX_ANDROID_BUILD_TOOLS_VERSION/jack.jar
	TERMUX_JILL=$ANDROID_HOME/build-tools/$TERMUX_ANDROID_BUILD_TOOLS_VERSION/jill.jar

	TERMUX_COMMON_CACHEDIR="$TERMUX_TOPDIR/_cache"
	TERMUX_DEBDIR="$TERMUX_SCRIPTDIR/debs"

	TERMUX_STANDALONE_TOOLCHAIN="$TERMUX_TOPDIR/_lib/${TERMUX_NDK_VERSION}-${TERMUX_ARCH}-${TERMUX_API_LEVEL}"
	# Bump the below version if a change is made in toolchain setup to ensure
	# that everyone gets an updated toolchain:
	TERMUX_STANDALONE_TOOLCHAIN+="-v6"

	export prefix=${TERMUX_PREFIX}
	export PREFIX=${TERMUX_PREFIX}

	TERMUX_PKG_BUILDDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/build
	TERMUX_PKG_CACHEDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/cache
	TERMUX_PKG_MASSAGEDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/massage
	TERMUX_PKG_PACKAGEDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/package
	TERMUX_PKG_SRCDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/src
	TERMUX_PKG_SHA256=""
	TERMUX_PKG_TMPDIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/tmp
	TERMUX_PKG_HOSTBUILD_DIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/host-build
	TERMUX_PKG_PLATFORM_INDEPENDENT=""
	TERMUX_PKG_NO_DEVELSPLIT=""
	TERMUX_PKG_REVISION="0" # http://www.debian.org/doc/debian-policy/ch-controlfields.html#s-f-Version
	TERMUX_PKG_EXTRA_CONFIGURE_ARGS=""
	TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS=""
	TERMUX_PKG_EXTRA_MAKE_ARGS=""
	TERMUX_PKG_BUILD_IN_SRC=""
	TERMUX_PKG_RM_AFTER_INSTALL=""
	TERMUX_PKG_DEPENDS=""
	TERMUX_PKG_HOMEPAGE=""
	TERMUX_PKG_DESCRIPTION="FIXME:Add description"
	TERMUX_PKG_FOLDERNAME=""
	TERMUX_PKG_KEEP_STATIC_LIBRARIES="true"
	TERMUX_PKG_ESSENTIAL=""
	TERMUX_PKG_CONFLICTS="" # https://www.debian.org/doc/debian-policy/ch-relationships.html#s-conflicts
	TERMUX_PKG_REPLACES=""
	TERMUX_PKG_CONFFILES=""
	TERMUX_PKG_INCLUDE_IN_DEVPACKAGE=""
	TERMUX_PKG_DEVPACKAGE_DEPENDS=""
	# Set if a host build should be done in TERMUX_PKG_HOSTBUILD_DIR:
	TERMUX_PKG_HOSTBUILD=""
	TERMUX_PKG_MAINTAINER="Edmund Kostelnik <edmund.kosovo@gmail.com>"
	TERMUX_PKG_CLANG=no # does nothing for cmake based packages. clang is chosen by cmake
	TERMUX_PKG_FORCE_CMAKE=no # if the package has autotools as well as cmake, then set this to prefer cmake

	unset CFLAGS CPPFLAGS LDFLAGS CXXFLAGS
}

# Save away and restore build setups which may change between builds.
termux_step_handle_buildarch() {
	# If $TERMUX_PREFIX already exists, it may have been built for a different arch
	local TERMUX_ARCH_FILE=/data/data/com.termux/files/usr/.TERMUX_ARCH
	echo "$TERMUX_ARCH" > $TERMUX_ARCH_FILE
}

# Source the package build script and start building. No to be overridden by packages.
termux_step_start_build() {
	# shellcheck source=/dev/null
	source "$TERMUX_PKG_BUILDER_SCRIPT"

	if [ -n "${TERMUX_PKG_BLACKLISTED_ARCHES:=""}" ] && [ "$TERMUX_PKG_BLACKLISTED_ARCHES" != "${TERMUX_PKG_BLACKLISTED_ARCHES/$TERMUX_ARCH/}" ]; then
		echo "Skipping building $TERMUX_PKG_NAME for arch $TERMUX_ARCH"
		exit 0
	fi

	if [ -z "${TERMUX_SKIP_DEPCHECK:=""}" ]; then
		local p TERMUX_ALL_DEPS
		TERMUX_ALL_DEPS=$(./scripts/buildorder.py "$TERMUX_PKG_NAME")
		for p in $TERMUX_ALL_DEPS; do
			if [ "$p" != "$TERMUX_PKG_NAME" ]; then
				echo "Building dependency $p if necessary..."
				./build-package.sh -a $TERMUX_ARCH -s "$p"
			fi
		done
	fi

	TERMUX_PKG_FULLVERSION=$TERMUX_PKG_VERSION
	if [ "$TERMUX_PKG_REVISION" != "0" ] || [ "$TERMUX_PKG_FULLVERSION" != "${TERMUX_PKG_FULLVERSION/-/}" ]; then
		# "0" is the default revision, so only include it if the upstream versions contains "-" itself
		TERMUX_PKG_FULLVERSION+="-$TERMUX_PKG_REVISION"
	fi

	if [ -z "$TERMUX_DEBUG" ] &&
	   [ -z "${TERMUX_FORCE_BUILD+x}" ] &&
	   [ -e "/data/data/com.termux/files/usr/.built-packages/$TERMUX_PKG_NAME" ]; then
		if [ "$(cat "/data/data/com.termux/files/usr/.built-packages/$TERMUX_PKG_NAME")" = "$TERMUX_PKG_FULLVERSION" ]; then
			echo "$TERMUX_PKG_NAME@$TERMUX_PKG_FULLVERSION built - skipping (rm /data/data/com.termux/files/usr/.built-packages/$TERMUX_PKG_NAME to force rebuild)"
			exit 0
		fi
	fi

	# Cleanup old state:
	rm -Rf "$TERMUX_PKG_BUILDDIR" \
		"$TERMUX_PKG_PACKAGEDIR" \
		"$TERMUX_PKG_SRCDIR" \
		"$TERMUX_PKG_TMPDIR" \
		"$TERMUX_PKG_MASSAGEDIR"

	# Ensure folders present (but not $TERMUX_PKG_SRCDIR, it will be created in build)
	mkdir -p "$TERMUX_COMMON_CACHEDIR" \
		"$TERMUX_DEBDIR" \
		 "$TERMUX_PKG_BUILDDIR" \
		 "$TERMUX_PKG_PACKAGEDIR" \
		 "$TERMUX_PKG_TMPDIR" \
		 "$TERMUX_PKG_CACHEDIR" \
		 "$TERMUX_PKG_MASSAGEDIR" \
		 $TERMUX_PREFIX/{bin,etc,lib,libexec,share,tmp,include}

	if [ -n "$TERMUX_PKG_BUILD_IN_SRC" ]; then
		echo "Building in src due to TERMUX_PKG_BUILD_IN_SRC being set" > "$TERMUX_PKG_BUILDDIR/BUILDING_IN_SRC.txt"
		TERMUX_PKG_BUILDDIR=$TERMUX_PKG_SRCDIR
	fi

	echo "termux - building $TERMUX_PKG_NAME for arch $TERMUX_ARCH..."
	test -t 1 && printf "\033]0;%s...\007" "$TERMUX_PKG_NAME"

	# Avoid exporting PKG_CONFIG_LIBDIR until after termux_step_host_build.
	export TERMUX_PKG_CONFIG_LIBDIR=$TERMUX_PREFIX/lib/pkgconfig
	# Add a pkg-config file for the system zlib.
	mkdir -p "$TERMUX_PKG_CONFIG_LIBDIR"
	cat > "$TERMUX_PKG_CONFIG_LIBDIR/zlib.pc" <<-HERE
		Name: zlib
		Description: zlib compression library
		Version: 1.2.8
		Requires:
		Libs: -lz
	HERE

	# Keep track of when build started so we can see what files have been created.
	# We start by sleeping so that any generated files above (such as zlib.pc) get
	# an older timestamp than the TERMUX_BUILD_TS_FILE.
	sleep 1
	TERMUX_BUILD_TS_FILE=$TERMUX_PKG_TMPDIR/timestamp_$TERMUX_PKG_NAME
	touch "$TERMUX_BUILD_TS_FILE"
}

# Run just after sourcing $TERMUX_PKG_BUILDER_SCRIPT. May be overridden by packages.
termux_step_extract_package() {
	if [ -z "${TERMUX_PKG_SRCURL:=""}" ]; then
		mkdir -p "$TERMUX_PKG_SRCDIR"
		return
	fi
	cd "$TERMUX_PKG_TMPDIR"
	local filename
	filename=$(basename "$TERMUX_PKG_SRCURL")
	local file="$TERMUX_PKG_CACHEDIR/$filename"
	termux_download "$TERMUX_PKG_SRCURL" "$file" "$TERMUX_PKG_SHA256"

	if [ "x$TERMUX_PKG_FOLDERNAME" = "x" ]; then
		folder="${filename%%.t*}" && folder="${folder%%.zip}"
		folder="${folder/_/-}" # dpkg uses _ in tar filename, but - in folder
	else
		folder=$TERMUX_PKG_FOLDERNAME
	fi
	rm -Rf $folder
	if [ "${file##*.}" = zip ]; then
		unzip -q "$file"
	else
		tar xf "$file"
	fi
	mv $folder "$TERMUX_PKG_SRCDIR"
}

# Hook for packages to act just after the package has been extracted.
# Invoked in $TERMUX_PKG_SRCDIR.
termux_step_post_extract_package() {
        return
}

# Optional host build. Not to be overridden by packages.
termux_step_handle_hostbuild() {
	if [ "x$TERMUX_PKG_HOSTBUILD" = "x" ]; then return; fi

	cd "$TERMUX_PKG_SRCDIR"
	for patch in $TERMUX_PKG_BUILDER_DIR/*.patch.beforehostbuild; do
		test -f "$patch" && sed "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$patch" | patch --silent -p1
	done

	local TERMUX_HOSTBUILD_MARKER="$TERMUX_PKG_HOSTBUILD_DIR/TERMUX_BUILT_FOR_$TERMUX_PKG_VERSION"
	if [ ! -f "$TERMUX_HOSTBUILD_MARKER" ]; then
		rm -Rf "$TERMUX_PKG_HOSTBUILD_DIR"
		mkdir -p "$TERMUX_PKG_HOSTBUILD_DIR"
		cd "$TERMUX_PKG_HOSTBUILD_DIR"
		termux_step_host_build
		touch "$TERMUX_HOSTBUILD_MARKER"
	fi
}

# Perform a host build. Will be called in $TERMUX_PKG_HOSTBUILD_DIR.
# After termux_step_post_extract_package() and before termux_step_patch_package()
termux_step_host_build() {
	"$TERMUX_PKG_SRCDIR/configure" ${TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS}
	make -j $TERMUX_MAKE_PROCESSES
}

# Setup a standalone Android NDK toolchain. Not to be overridden by packages.
termux_step_setup_toolchain() {
	# We put this after system PATH to avoid picking up toolchain stripped python
	export PATH=$PATH:$TERMUX_STANDALONE_TOOLCHAIN/bin

	export CFLAGS="-g3 -O1 -fstack-protector --param ssp-buffer-size=4 -D_FORTIFY_SOURCE=2 -w"
	export CXXFLAGS="$CFLAGS"
	export CPPFLAGS="-I${TERMUX_PREFIX}/include"
	export LDFLAGS="-L${TERMUX_PREFIX}/lib -Wl,-rpath=$TERMUX_PREFIX/lib -Wl,--enable-new-dtags"


	if [ "$TERMUX_PKG_CLANG" = "no" ]; then
		export AS=${TERMUX_HOST_PLATFORM}-gcc
		export CC=$TERMUX_HOST_PLATFORM-gcc
		export CXX=$TERMUX_HOST_PLATFORM-g++
		LDFLAGS+=" -specs=$TERMUX_SCRIPTDIR/termux.spec"
		CFLAGS+=" -specs=$TERMUX_SCRIPTDIR/termux.spec"
	else
		export AS=${TERMUX_HOST_PLATFORM}-clang
		export CC=$TERMUX_HOST_PLATFORM-clang
		export CXX=$TERMUX_HOST_PLATFORM-clang++
	fi

	export AR=$TERMUX_HOST_PLATFORM-ar
	export CPP=${TERMUX_HOST_PLATFORM}-cpp
	export CC_FOR_BUILD=gcc
	export LD=$TERMUX_HOST_PLATFORM-ld
	export OBJDUMP=$TERMUX_HOST_PLATFORM-objdump
	# Setup pkg-config for cross-compiling:
	export PKG_CONFIG=$TERMUX_STANDALONE_TOOLCHAIN/bin/${TERMUX_HOST_PLATFORM}-pkg-config
	export RANLIB=$TERMUX_HOST_PLATFORM-ranlib
	export READELF=$TERMUX_HOST_PLATFORM-readelf
	export STRIP=$TERMUX_HOST_PLATFORM-strip

	if [ "$TERMUX_PKG_DEPENDS" != "${TERMUX_PKG_DEPENDS/libandroid-support/}" ]; then
		CPPFLAGS+=" -isystem $TERMUX_PREFIX/include/libandroid-support"
		LDFLAGS+=" -landroid-support"
	fi

	export ac_cv_func_getpwent=no
	export ac_cv_func_getpwnam=no
	export ac_cv_func_getpwuid=no
	export ac_cv_func_sigsetmask=no

	if [ ! -d $TERMUX_STANDALONE_TOOLCHAIN ]; then
		# Do not put toolchain in place until we are done with setup, to avoid having a half setup
		# toolchain left in place if something goes wrong (or process is just aborted):
		local _TERMUX_TOOLCHAIN_TMPDIR=${TERMUX_STANDALONE_TOOLCHAIN}-tmp
		rm -Rf $_TERMUX_TOOLCHAIN_TMPDIR

		local _NDK_ARCHNAME=arm64

		"$NDK/build/tools/make_standalone_toolchain.py" \
			--api "$TERMUX_API_LEVEL" \
			--arch $_NDK_ARCHNAME \
			--install-dir $_TERMUX_TOOLCHAIN_TMPDIR

		local wrapped plusplus CLANG_TARGET=$TERMUX_HOST_PLATFORM
		for wrapped in ${TERMUX_HOST_PLATFORM}-clang clang; do
			for plusplus in "" "++"; do
				local FILE_TO_REPLACE=$_TERMUX_TOOLCHAIN_TMPDIR/bin/${wrapped}${plusplus}
				if [ ! -f $FILE_TO_REPLACE ]; then
					termux_error_exit "No toolchain file to override: $FILE_TO_REPLACE"
				fi
				cp "$TERMUX_SCRIPTDIR/scripts/clang-pie-wrapper" $FILE_TO_REPLACE
				sed -i "s/COMPILER/clang50$plusplus/" $FILE_TO_REPLACE
				sed -i "s/CLANG_TARGET/$CLANG_TARGET/" $FILE_TO_REPLACE
			done
		done

		cp $_TERMUX_TOOLCHAIN_TMPDIR/bin/aarch64-linux-android-ld.gold \
		   $_TERMUX_TOOLCHAIN_TMPDIR/bin/aarch64-linux-android-ld
		cp $_TERMUX_TOOLCHAIN_TMPDIR/aarch64-linux-android/bin/ld.gold \
		   $_TERMUX_TOOLCHAIN_TMPDIR/aarch64-linux-android/bin/ld

		cd $_TERMUX_TOOLCHAIN_TMPDIR/sysroot

		for f in $TERMUX_SCRIPTDIR/ndk-patches/*.patch; do
			sed "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$f" | \
				sed "s%\@TERMUX_HOME\@%${TERMUX_ANDROID_HOME}%g" | \
				patch --silent -p1;
		done
		cp "$TERMUX_SCRIPTDIR"/ndk-patches/{elf.h,sysexits.h,ifaddrs.h} usr/include

		rm usr/include/sys/{shm.h,sem.h}

		sed -i "s/define __ANDROID_API__ __ANDROID_API_FUTURE__/define __ANDROID_API__ $TERMUX_API_LEVEL/" \
			usr/include/android/api-level.h

		local _LIBDIR=usr/lib

		for file in zconf.h zlib.h; do
			curl -o usr/include/$file \
			        https://raw.githubusercontent.com/madler/zlib/v1.2.8/$file
		done
		unset file

		mv $_TERMUX_TOOLCHAIN_TMPDIR $TERMUX_STANDALONE_TOOLCHAIN
	fi

	if [ ! -f $TERMUX_PREFIX/lib/libstdc++.so ]; then
		mkdir -p "$TERMUX_PREFIX/lib"
		cd "$TERMUX_PREFIX/lib"
		_STL_LIBFILE=$TERMUX_STANDALONE_TOOLCHAIN/${TERMUX_HOST_PLATFORM}/lib/libgnustl_shared.so
		cp "$_STL_LIBFILE" .
		$STRIP --strip-unneeded libgnustl_shared.so
		ln -f -s libgnustl_shared.so libstdc++.so
	fi

	export PKG_CONFIG_LIBDIR="$TERMUX_PKG_CONFIG_LIBDIR"
	local _HOST_PKGCONFIG
	_HOST_PKGCONFIG=$(which pkg-config)
	mkdir -p $TERMUX_STANDALONE_TOOLCHAIN/bin "$PKG_CONFIG_LIBDIR"
	cat > "$PKG_CONFIG" <<-HERE
		#!/bin/bash
		export PKG_CONFIG_DIR=
		export PKG_CONFIG_LIBDIR=$PKG_CONFIG_LIBDIR
		exec $_HOST_PKGCONFIG "\$@"
	HERE
	chmod +x "$PKG_CONFIG"
}

# Apply all *.patch files for the package. Not to be overridden by packages.
termux_step_patch_package() {
	cd "$TERMUX_PKG_SRCDIR"
	# Suffix patch with ".patch32" or ".patch64" to only apply for these bitnesses:
	shopt -s nullglob
	for patch in $TERMUX_PKG_BUILDER_DIR/*.patch{$TERMUX_ARCH_BITS,}; do
		test -f "$patch" && sed "s%\@TERMUX_PREFIX\@%${TERMUX_PREFIX}%g" "$patch" | \
			sed "s%\@TERMUX_HOME\@%${TERMUX_ANDROID_HOME}%g" | \
			patch --silent -p1
	done
	shopt -u nullglob
}

# Replace autotools build-aux/config.{sub,guess} with ours to add android targets.
termux_step_replace_guess_scripts () {
	cd "$TERMUX_PKG_SRCDIR"
	find . -name config.sub -exec chmod u+w '{}' \; -exec cp "$TERMUX_SCRIPTDIR/scripts/config.sub" '{}' \;
	find . -name config.guess -exec chmod u+w '{}' \; -exec cp "$TERMUX_SCRIPTDIR/scripts/config.guess" '{}' \;
}

# For package scripts to override. Called in $TERMUX_PKG_BUILDDIR.
termux_step_pre_configure() {
	return
}

termux_step_configure_autotools () {
	if [ ! -e "$TERMUX_PKG_SRCDIR/configure" ]; then return; fi

	ENABLE_STATIC="--enable-static"
	DISABLE_STATIC="--disable-static"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--enable-static/}" ]; then
		# Do not --disable-static if package explicitly enables it (e.g. gdb needs enable-static to build)
		DISABLE_STATIC=""
	fi

	DISABLE_NLS="--disable-nls"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--enable-nls/}" ]; then
		# Do not --disable-nls if package explicitly enables it (for gettext itself)
		DISABLE_NLS=""
	fi

	ENABLE_SHARED="--enable-shared"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--disable-shared/}" ]; then
		ENABLE_SHARED=""
	fi
	BUILD_FLAG="--build=$TERMUX_HOST_PLATFORM"
	HOST_FLAG="--host=$TERMUX_HOST_PLATFORM"
	if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--host=/}" ]; then
		HOST_FLAG=""
	fi
	LIBEXEC_FLAG="--libexecdir=$TERMUX_PREFIX/libexec"
        if [ "$TERMUX_PKG_EXTRA_CONFIGURE_ARGS" != "${TERMUX_PKG_EXTRA_CONFIGURE_ARGS/--libexecdir=/}" ]; then
                LIBEXEC_FLAG=""
        fi

	# Some packages provides a $PKG-config script which some configure scripts pickup instead of pkg-config:
	mkdir "$TERMUX_PKG_TMPDIR/config-scripts"
	for f in $TERMUX_PREFIX/bin/*config; do
		test -f "$f" && cp "$f" "$TERMUX_PKG_TMPDIR/config-scripts"
	done
	export PATH=$TERMUX_PKG_TMPDIR/config-scripts:$PATH

	# Avoid gnulib wrapping of functions when cross compiling. See
	# http://wiki.osdev.org/Cross-Porting_Software#Gnulib
	# https://gitlab.com/sortix/sortix/wikis/Gnulib
	# https://github.com/termux/termux-packages/issues/76
	local AVOID_GNULIB=""
	AVOID_GNULIB+=" ac_cv_func_calloc_0_nonnull=yes"
	AVOID_GNULIB+=" ac_cv_func_chown_works=yes"
	AVOID_GNULIB+=" ac_cv_func_getgroups_works=yes"
	AVOID_GNULIB+=" ac_cv_func_malloc_0_nonnull=yes"
	AVOID_GNULIB+=" ac_cv_func_realloc_0_nonnull=yes"
	AVOID_GNULIB+=" am_cv_func_working_getline=yes"
	AVOID_GNULIB+=" gl_cv_func_dup2_works=yes"
	AVOID_GNULIB+=" gl_cv_func_fcntl_f_dupfd_cloexec=yes"
	AVOID_GNULIB+=" gl_cv_func_fcntl_f_dupfd_works=yes"
	AVOID_GNULIB+=" gl_cv_func_fnmatch_posix=yes"
	AVOID_GNULIB+=" gl_cv_func_getcwd_abort_bug=no"
	AVOID_GNULIB+=" gl_cv_func_getcwd_null=yes"
	AVOID_GNULIB+=" gl_cv_func_getcwd_path_max=yes"
	AVOID_GNULIB+=" gl_cv_func_getcwd_posix_signature=yes"
	AVOID_GNULIB+=" gl_cv_func_gettimeofday_clobber=no"
	AVOID_GNULIB+=" gl_cv_func_gettimeofday_posix_signature=yes"
	AVOID_GNULIB+=" gl_cv_func_link_works=yes"
	AVOID_GNULIB+=" gl_cv_func_lstat_dereferences_slashed_symlink=yes"
	AVOID_GNULIB+=" gl_cv_func_malloc_0_nonnull=yes"
	AVOID_GNULIB+=" gl_cv_func_memchr_works=yes"
	AVOID_GNULIB+=" gl_cv_func_mkdir_trailing_dot_works=yes"
	AVOID_GNULIB+=" gl_cv_func_mkdir_trailing_slash_works=yes"
	AVOID_GNULIB+=" gl_cv_func_mkfifo_works=yes"
	AVOID_GNULIB+=" gl_cv_func_realpath_works=yes"
	AVOID_GNULIB+=" gl_cv_func_select_detects_ebadf=yes"
	AVOID_GNULIB+=" gl_cv_func_snprintf_posix=yes"
	AVOID_GNULIB+=" gl_cv_func_snprintf_retval_c99=yes"
	AVOID_GNULIB+=" gl_cv_func_snprintf_truncation_c99=yes"
	AVOID_GNULIB+=" gl_cv_func_stat_dir_slash=yes"
	AVOID_GNULIB+=" gl_cv_func_stat_file_slash=yes"
	AVOID_GNULIB+=" gl_cv_func_strerror_0_works=yes"
	AVOID_GNULIB+=" gl_cv_func_symlink_works=yes"
	AVOID_GNULIB+=" gl_cv_func_tzset_clobber=no"
	AVOID_GNULIB+=" gl_cv_func_unlink_honors_slashes=yes"
	AVOID_GNULIB+=" gl_cv_func_unlink_honors_slashes=yes"
	AVOID_GNULIB+=" gl_cv_func_vsnprintf_posix=yes"
	AVOID_GNULIB+=" gl_cv_func_vsnprintf_zerosize_c99=yes"
	AVOID_GNULIB+=" gl_cv_func_wcwidth_works=yes"
	AVOID_GNULIB+=" gl_cv_func_working_getdelim=yes"
	AVOID_GNULIB+=" gl_cv_func_working_mkstemp=yes"
	AVOID_GNULIB+=" gl_cv_func_working_mktime=yes"
	AVOID_GNULIB+=" gl_cv_func_working_strerror=yes"
	AVOID_GNULIB+=" gl_cv_header_working_fcntl_h=yes"
	AVOID_GNULIB+=" gl_cv_C_locale_sans_EILSEQ=yes"

	# NOTE: We do not want to quote AVOID_GNULIB as we want word expansion.
	env $AVOID_GNULIB "$TERMUX_PKG_SRCDIR/configure" \
		--disable-dependency-tracking \
		--disable-option-checking \
		--prefix=$TERMUX_PREFIX \
		--disable-rpath --disable-rpath-hack \
		$TERMUX_PKG_EXTRA_CONFIGURE_ARGS \
		$BUILD_FLAG \
		$DISABLE_NLS \
		$ENABLE_SHARED \
		$ENABLE_STATIC \
		$LIBEXEC_FLAG
}

termux_step_configure_cmake () {
	termux_setup_cmake

	local TOOLCHAIN_ARGS="-DCMAKE_ANDROID_STANDALONE_TOOLCHAIN=$TERMUX_STANDALONE_TOOLCHAIN"
	local BUILD_TYPE=Debug

	local CMAKE_PROC=aarch64
	
	cmake -G 'Unix Makefiles' "$TERMUX_PKG_SRCDIR" \
		-DCMAKE_AR="$(which $AR)" \
		-DCMAKE_RANLIB="$(which $RANLIB)" \
		-DCMAKE_BUILD_TYPE=$BUILD_TYPE \
		-DCMAKE_CROSSCOMPILING=False \
		-DCMAKE_C_FLAGS="$CFLAGS $CPPFLAGS" \
		-DCMAKE_CXX_FLAGS="$CXXFLAGS $CPPFLAGS" \
		-DCMAKE_LINKER="$TERMUX_STANDALONE_TOOLCHAIN/bin/$LD $LDFLAGS" \
		-DCMAKE_FIND_ROOT_PATH=$TERMUX_PREFIX \
		-DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
		-DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
		-DCMAKE_INSTALL_PREFIX=$TERMUX_PREFIX \
		-DCMAKE_MAKE_PROGRAM=`which make` \
		-DCMAKE_SYSTEM_PROCESSOR=$CMAKE_PROC \
		-DCMAKE_SYSTEM_NAME=Android \
		-DCMAKE_SYSTEM_VERSION=21 \
		-DCMAKE_SKIP_INSTALL_RPATH=ON \
		-DCMAKE_USE_SYSTEM_LIBRARIES=True \
		-DBUILD_TESTING=OFF \
		$TERMUX_PKG_EXTRA_CONFIGURE_ARGS $TOOLCHAIN_ARGS
}

termux_step_configure () {
	if [ "$TERMUX_PKG_FORCE_CMAKE" == 'no' ] && [ -f "$TERMUX_PKG_SRCDIR/configure" ]; then
		termux_step_configure_autotools
	elif [ -f "$TERMUX_PKG_SRCDIR/CMakeLists.txt" ]; then
		termux_step_configure_cmake
	fi
}

termux_step_post_configure () {
	return
}

termux_step_make() {
	if ls ./*akefile &> /dev/null; then
		if [ -z "$TERMUX_PKG_EXTRA_MAKE_ARGS" ]; then
			make -j $TERMUX_MAKE_PROCESSES
		else
			make -j $TERMUX_MAKE_PROCESSES ${TERMUX_PKG_EXTRA_MAKE_ARGS}
		fi
	fi
}

termux_step_make_install() {
	if ls ./*akefile &> /dev/null; then
		: "${TERMUX_PKG_MAKE_INSTALL_TARGET:="install"}"
		# Some packages have problem with parallell install, and it does not buy much, so use -j 1.
		if [ -z "$TERMUX_PKG_EXTRA_MAKE_ARGS" ]; then
			make -j 1 ${TERMUX_PKG_MAKE_INSTALL_TARGET}
		else
			make -j 1 ${TERMUX_PKG_EXTRA_MAKE_ARGS} ${TERMUX_PKG_MAKE_INSTALL_TARGET}
		fi
	fi
}

# Hook function for package scripts to override.
termux_step_post_make_install() {
	return
}

termux_step_extract_into_massagedir() {
	local TARBALL_ORIG=$TERMUX_PKG_PACKAGEDIR/${TERMUX_PKG_NAME}_orig.tar.gz

	# Build diff tar with what has changed during the build:
	cd $TERMUX_PREFIX
	tar -N "$TERMUX_BUILD_TS_FILE" -czf "$TARBALL_ORIG" .

	# Extract tar in order to massage it
	mkdir -p "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
	cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
	tar xf "$TARBALL_ORIG"
	rm "$TARBALL_ORIG"
}

termux_step_massage() {
	cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"

	# Remove lib/charset.alias which is installed by gettext-using packages:
	rm -f lib/charset.alias

	# Remove non-english man pages:
	test -d share/man && (cd share/man; for f in `ls | grep -v man`; do rm -Rf $f; done )

	if [ -z "${TERMUX_PKG_KEEP_INFOPAGES+x}" ]; then
		# Remove info pages:
		rm -Rf share/info
	fi

	# Remove locale files we're not interested in::
	rm -Rf share/locale
	if [ -z "${TERMUX_PKG_KEEP_SHARE_DOC+x}" ]; then
		# Remove info pages:
		rm -Rf share/doc
	fi

	# Remove old kept libraries (readline):
	find . -name '*.old' -delete

	# Move over sbin to bin:
	for file in sbin/*; do if test -f "$file"; then mv "$file" bin/; fi; done

	find . -type d -empty -delete # Remove empty directories
	# Remove world permissions and add write permissions.
	# The -f flag is used to suppress warnings about dangling symlinks (such
	# as ones to /system/... which may not exist on the build machine):
        find . -exec chmod -f u+w,g-rwx,o-rwx '{}' \;

	# Fix shebang paths:
	while IFS= read -r -d '' file
	do
		head -c 100 "$file" | grep -E "^#\!.*\\/bin\\/.*" | grep -q -E -v "^#\! ?\\/system" && sed --follow-symlinks -i -E "1 s@^#\!(.*)/bin/(.*)@#\!$TERMUX_PREFIX/bin/\2@" "$file"
	done < <(find -L . -type f -print0)

	test ! -z "$TERMUX_PKG_RM_AFTER_INSTALL" && rm -Rf $TERMUX_PKG_RM_AFTER_INSTALL

	find . -type d -empty -delete # Remove empty directories

	# Sub packages:
	if [ -d include ] && [ -z "${TERMUX_PKG_NO_DEVELSPLIT}" ]; then
		# Add virtual -dev sub package if there are include files:
		local _DEVEL_SUBPACKAGE_FILE=$TERMUX_PKG_TMPDIR/${TERMUX_PKG_NAME}-dev.subpackage.sh
		echo TERMUX_SUBPKG_INCLUDE=\"include share/vala share/man/man3 lib/pkgconfig share/aclocal lib/cmake $TERMUX_PKG_INCLUDE_IN_DEVPACKAGE\" > "$_DEVEL_SUBPACKAGE_FILE"
		echo "TERMUX_SUBPKG_DESCRIPTION=\"Development files for ${TERMUX_PKG_NAME}\"" >> "$_DEVEL_SUBPACKAGE_FILE"
		if [ -n "$TERMUX_PKG_DEVPACKAGE_DEPENDS" ]; then
			echo "TERMUX_SUBPKG_DEPENDS=\"$TERMUX_PKG_NAME,$TERMUX_PKG_DEVPACKAGE_DEPENDS\"" >> "$_DEVEL_SUBPACKAGE_FILE"
		else
			echo "TERMUX_SUBPKG_DEPENDS=\"$TERMUX_PKG_NAME\"" >> "$_DEVEL_SUBPACKAGE_FILE"
		fi
	fi
	# Now build all sub packages
	rm -Rf "$TERMUX_TOPDIR/$TERMUX_PKG_NAME/subpackages"
	for subpackage in $TERMUX_PKG_BUILDER_DIR/*.subpackage.sh $TERMUX_PKG_TMPDIR/*subpackage.sh; do
		test ! -f "$subpackage" && continue
		local SUB_PKG_NAME
		SUB_PKG_NAME=$(basename "$subpackage" .subpackage.sh)
		# Default value is same as main package, but sub package may override:
		local TERMUX_SUBPKG_PLATFORM_INDEPENDENT=$TERMUX_PKG_PLATFORM_INDEPENDENT
		local SUB_PKG_DIR=$TERMUX_TOPDIR/$TERMUX_PKG_NAME/subpackages/$SUB_PKG_NAME
		local TERMUX_SUBPKG_DEPENDS=""
		local TERMUX_SUBPKG_CONFLICTS=""
		local TERMUX_SUBPKG_CONFFILES=""
		local SUB_PKG_MASSAGE_DIR=$SUB_PKG_DIR/massage/$TERMUX_PREFIX
		local SUB_PKG_PACKAGE_DIR=$SUB_PKG_DIR/package
		mkdir -p "$SUB_PKG_MASSAGE_DIR" "$SUB_PKG_PACKAGE_DIR"

		# shellcheck source=/dev/null
		source $subpackage

		for includeset in $TERMUX_SUBPKG_INCLUDE; do
			local _INCLUDE_DIRSET
			_INCLUDE_DIRSET=$(dirname "$includeset")
			test "$_INCLUDE_DIRSET" = "." && _INCLUDE_DIRSET=""
			if [ -e "$includeset" ] || [ -L "$includeset" ]; then
				# Add the -L clause to handle relative symbolic links:
				mkdir -p "$SUB_PKG_MASSAGE_DIR/$_INCLUDE_DIRSET"
				mv "$includeset" "$SUB_PKG_MASSAGE_DIR/$_INCLUDE_DIRSET"
			fi
		done

		local SUB_PKG_ARCH=$TERMUX_ARCH
		test -n "$TERMUX_SUBPKG_PLATFORM_INDEPENDENT" && SUB_PKG_ARCH=all

		cd "$SUB_PKG_DIR/massage"
		local SUB_PKG_INSTALLSIZE
		SUB_PKG_INSTALLSIZE=$(du -sk . | cut -f 1)
		tar -cJf "$SUB_PKG_PACKAGE_DIR/data.tar.xz" .

		mkdir -p DEBIAN
		cd DEBIAN
		cat > control <<-HERE
			Package: $SUB_PKG_NAME
			Architecture: ${SUB_PKG_ARCH}
			Installed-Size: ${SUB_PKG_INSTALLSIZE}
			Maintainer: $TERMUX_PKG_MAINTAINER
			Version: $TERMUX_PKG_FULLVERSION
			Description: $TERMUX_SUBPKG_DESCRIPTION
			Homepage: $TERMUX_PKG_HOMEPAGE
		HERE
		test ! -z "$TERMUX_SUBPKG_DEPENDS" && echo "Depends: $TERMUX_SUBPKG_DEPENDS" >> control
		test ! -z "$TERMUX_SUBPKG_CONFLICTS" && echo "Conflicts: $TERMUX_SUBPKG_CONFLICTS" >> control
		tar -cJf "$SUB_PKG_PACKAGE_DIR/control.tar.xz" .

		for f in $TERMUX_SUBPKG_CONFFILES; do echo "$TERMUX_PREFIX/$f" >> conffiles; done

		# Create the actual .deb file:
		TERMUX_SUBPKG_DEBFILE=$TERMUX_DEBDIR/${SUB_PKG_NAME}_${TERMUX_PKG_FULLVERSION}_${SUB_PKG_ARCH}.deb
		test ! -f "$TERMUX_COMMON_CACHEDIR/debian-binary" && echo "2.0" > "$TERMUX_COMMON_CACHEDIR/debian-binary"
		ar cr "$TERMUX_SUBPKG_DEBFILE" \
				   "$TERMUX_COMMON_CACHEDIR/debian-binary" \
				   "$SUB_PKG_PACKAGE_DIR/control.tar.xz" \
				   "$SUB_PKG_PACKAGE_DIR/data.tar.xz"

		# Go back to main package:
		cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
	done

	# .. remove empty directories (NOTE: keep this last):
	find . -type d -empty -delete
	# Make sure user can read and write all files (problem with dpkg otherwise):
	chmod -R u+rw .
}

termux_step_post_massage() {
	return
}

# Create data.tar.gz with files to package. Not to be overridden by package scripts.
termux_step_create_datatar() {
	# Create data tarball containing files to package:
	cd "$TERMUX_PKG_MASSAGEDIR"

	local HARDLINKS="$(find . -type f -links +1)"
	if [ -n "$HARDLINKS" ]; then
		termux_error_exit "Package contains hard links: $HARDLINKS"
	fi

	if [ -z "${TERMUX_PKG_METAPACKAGE+x}" ] && [ "$(find . -type f)" = "" ]; then
		termux_error_exit "No files in package"
	fi
	tar -cJf "$TERMUX_PKG_PACKAGEDIR/data.tar.xz" .
}

termux_step_create_debscripts() {
	return
}

# Create the build deb file. Not to be overridden by package scripts.
termux_step_create_debfile() {
	# Get install size. This will be written as the "Installed-Size" deb field so is measured in 1024-byte blocks:
	local TERMUX_PKG_INSTALLSIZE
	TERMUX_PKG_INSTALLSIZE=$(du -sk . | cut -f 1)

	# From here on TERMUX_ARCH is set to "all" if TERMUX_PKG_PLATFORM_INDEPENDENT is set by the package
	test -n "$TERMUX_PKG_PLATFORM_INDEPENDENT" && TERMUX_ARCH=all

	mkdir -p DEBIAN
	cat > DEBIAN/control <<-HERE
		Package: $TERMUX_PKG_NAME
		Architecture: ${TERMUX_ARCH}
		Installed-Size: ${TERMUX_PKG_INSTALLSIZE}
		Maintainer: $TERMUX_PKG_MAINTAINER
		Version: $TERMUX_PKG_FULLVERSION
		Description: $TERMUX_PKG_DESCRIPTION
		Homepage: $TERMUX_PKG_HOMEPAGE
	HERE
	test ! -z "$TERMUX_PKG_DEPENDS" && echo "Depends: $TERMUX_PKG_DEPENDS" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_ESSENTIAL" && echo "Essential: yes" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_CONFLICTS" && echo "Conflicts: $TERMUX_PKG_CONFLICTS" >> DEBIAN/control
	test ! -z "$TERMUX_PKG_REPLACES" && echo "Replaces: $TERMUX_PKG_REPLACES" >> DEBIAN/control

	# Create DEBIAN/conffiles (see https://www.debian.org/doc/debian-policy/ap-pkg-conffiles.html):
	for f in $TERMUX_PKG_CONFFILES; do echo "$TERMUX_PREFIX/$f" >> DEBIAN/conffiles; done

	# Allow packages to create arbitrary control files.
	# XXX: Should be done in a better way without a function?
	cd DEBIAN
	termux_step_create_debscripts

	# Create control.tar.xz
	tar -cJf "$TERMUX_PKG_PACKAGEDIR/control.tar.xz" .

	test ! -f "$TERMUX_COMMON_CACHEDIR/debian-binary" && echo "2.0" > "$TERMUX_COMMON_CACHEDIR/debian-binary"
	TERMUX_PKG_DEBFILE=$TERMUX_DEBDIR/${TERMUX_PKG_NAME}_${TERMUX_PKG_FULLVERSION}_${TERMUX_ARCH}.deb
	# Create the actual .deb file:
	ar cr "$TERMUX_PKG_DEBFILE" \
	       "$TERMUX_COMMON_CACHEDIR/debian-binary" \
	       "$TERMUX_PKG_PACKAGEDIR/control.tar.xz" \
	       "$TERMUX_PKG_PACKAGEDIR/data.tar.xz"
}

# Finish the build. Not to be overridden by package scripts.
termux_step_finish_build() {
	echo "termux - build of '$TERMUX_PKG_NAME' done"
	test -t 1 && printf "\033]0;%s - DONE\007" "$TERMUX_PKG_NAME"
	mkdir -p /data/data/com.termux/files/usr/.built-packages
	echo "$TERMUX_PKG_FULLVERSION" > "/data/data/com.termux/files/usr/.built-packages/$TERMUX_PKG_NAME"
	exit 0
}

termux_step_handle_arguments "$@"
termux_step_setup_variables
termux_step_handle_buildarch
termux_step_start_build
termux_step_extract_package
cd "$TERMUX_PKG_SRCDIR"
termux_step_post_extract_package
termux_step_handle_hostbuild
termux_step_setup_toolchain
termux_step_patch_package
termux_step_replace_guess_scripts
cd "$TERMUX_PKG_SRCDIR"
termux_step_pre_configure
cd "$TERMUX_PKG_BUILDDIR"
termux_step_configure
cd "$TERMUX_PKG_BUILDDIR"
termux_step_post_configure
cd "$TERMUX_PKG_BUILDDIR"
termux_step_make
cd "$TERMUX_PKG_BUILDDIR"
termux_step_make_install
cd "$TERMUX_PKG_BUILDDIR"
termux_step_post_make_install
cd "$TERMUX_PKG_MASSAGEDIR"
termux_step_extract_into_massagedir
cd "$TERMUX_PKG_MASSAGEDIR"
termux_step_massage
cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX"
termux_step_post_massage
termux_step_create_datatar
termux_step_create_debfile
termux_step_finish_build
