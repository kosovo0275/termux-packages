TERMUX_PKG_HOMEPAGE=https://www.gnu.org/software/coreutils/
TERMUX_PKG_DESCRIPTION="Basic file, shell and text manipulation utilities from the GNU project"
TERMUX_PKG_VERSION=8.27
TERMUX_PKG_REVISION=2
TERMUX_PKG_SRCURL=https://mirrors.kernel.org/gnu/coreutils/coreutils-${TERMUX_PKG_VERSION}.tar.xz
TERMUX_PKG_SHA256=8891d349ee87b9ff7870f52b6d9312a9db672d2439d289bc57084771ca21656b
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="gl_cv_host_operating_system=Android --disable-threads --without-selinux --enable-single-binary=symlinks --enable-no-install-program=pinky,df,chroot,env,users,who,uptime"
TERMUX_PKG_EXTRA_HOSTBUILD_CONFIGURE_ARGS="$TERMUX_PKG_EXTRA_CONFIGURE_ARGS"
TERMUX_PKG_BUILD_IN_SRC=yes
TERMUX_PKG_HOSTBUILD=yes

termux_step_pre_configure() {
	cd $TERMUX_PKG_HOSTBUILD_DIR
	if [ -d confdir3/confdir3 ]; then
		mv confdir3/confdir3/ fred/
		rm -Rf fred/ confdir3/
	fi
}
