TERMUX_PKG_HOMEPAGE=https://www.perl.org/
TERMUX_PKG_DESCRIPTION="Capable, feature-rich programming language"
TERMUX_PKG_VERSION=5.26.0
TERMUX_PKG_SRCURL=http://www.cpan.org/src/5.0/perl-${TERMUX_PKG_VERSION}.tar.gz
TERMUX_PKG_SHA256=ebe7c66906d4fb55449380ab1b7e004eeef52c38d3443fa301f8e17a1a4cb67f
TERMUX_PKG_BUILD_IN_SRC="yes"
TERMUX_MAKE_PROCESSES=1
TERMUX_PKG_RM_AFTER_INSTALL="bin/perl${TERMUX_PKG_VERSION}"
TERMUX_PKG_NO_DEVELSPLIT=yes

termux_step_post_extract_package () {
	# This port uses perl-cross: http://arsv.github.io/perl-cross/
	local PERLCROSS_VERSION=1.1.5
	local PERLCROSS_FILE=perl-cross-${PERLCROSS_VERSION}.tar.gz
	local PERLCROSS_TAR=$TERMUX_PKG_CACHEDIR/$PERLCROSS_FILE
	if [ ! -f $PERLCROSS_TAR ]; then
		termux_download https://github.com/arsv/perl-cross/releases/download/$PERLCROSS_VERSION/$PERLCROSS_FILE \
		                $PERLCROSS_TAR \
		                0e719e75983b16c7726c2c9462f9498bb1fc4ad38c9f2513a65f3dd34e3decb3
	fi
	tar xf $PERLCROSS_TAR
	cd perl-cross-${PERLCROSS_VERSION}
	cp -Rf * ../

	# Remove old installation to force fresh:
	rm -rf $TERMUX_PREFIX/lib/perl5

	# Export variable used by Kid.pm.patch:
	export TERMUX_PKG_SRCDIR
}

termux_step_configure () {
	export PATH=$PATH:$TERMUX_STANDALONE_TOOLCHAIN/bin

	ORIG_AR=$AR; unset AR
	ORIG_AS=$AS; unset AS
	ORIG_CC=$CC; unset CC
	ORIG_CXX=$CXX; unset CXX
	ORIG_CPP=$CPP; unset CPP
	ORIG_CFLAGS=$CFLAGS; unset CFLAGS
	ORIG_CPPFLAGS=$CPPFLAGS; unset CPPFLAGS
	ORIG_CXXFLAGS=$CXXFLAGS; unset CXXFLAGS
	ORIG_LDFLAGS=$LDFLAGS; unset LDFLAGS
	ORIG_RANLIB=$RANLIB; unset RANLIB
	ORIG_LD=$LD; unset LD

	# Since we specify $TERMUX_PREFIX/bin/sh below for the shell
	# it will be run during the build, so temporarily (removed in
	# termux_step_post_make_install below) setup symlink:
	cd $TERMUX_PKG_BUILDDIR
	$TERMUX_PKG_SRCDIR/configure \
		--target=$TERMUX_HOST_PLATFORM \
		-Dsysroot=$TERMUX_STANDALONE_TOOLCHAIN/sysroot \
		-Dprefix=$TERMUX_PREFIX \
		-Dsh=$TERMUX_PREFIX/bin/bash \
		-Dcc=$ORIG_CC \
		-Duseshrplib
}

termux_step_post_make_install () {
	# Replace hardlinks with symlinks:
	cd $TERMUX_PREFIX/share/man/man1
	rm perlbug.1
	ln -s perlthanks.1 perlbug.1

	# Cleanup:
	cd $TERMUX_PREFIX/lib
	ln -f -s perl5/${TERMUX_PKG_VERSION}/${TERMUX_ARCH}-android/CORE/libperl.so libperl.so

	cd $TERMUX_PREFIX/include
	ln -f -s ../lib/perl5/${TERMUX_PKG_VERSION}/${TERMUX_ARCH}-android/CORE perl
	cd ../lib/perl5/${TERMUX_PKG_VERSION}/${TERMUX_ARCH}-android/
	chmod +w Config_heavy.pl
	sed 's',"--sysroot=$TERMUX_STANDALONE_TOOLCHAIN"/sysroot,"-I/data/data/com.termux/files/usr/include",'g' Config_heavy.pl > Config_heavy.pl.new
	sed 's',"$TERMUX_STANDALONE_TOOLCHAIN"/sysroot,"-I/data/data/com.termux/files",'g' Config_heavy.pl.new > Config_heavy.pl
	rm Config_heavy.pl.new
}
