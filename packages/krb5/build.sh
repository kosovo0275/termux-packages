TERMUX_PKG_HOMEPAGE=https://web.mit.edu/kerberos
TERMUX_PKG_DESCRIPTION="The Kerberos network authentication system"
TERMUX_PKG_VERSION=1.15.1
TERMUX_PKG_REVISION=2
TERMUX_PKG_DEPENDS="libandroid-support, libandroid-glob, readline, openssl, libutil, libdb"
TERMUX_PKG_SRCURL="https://web.mit.edu/kerberos/dist/krb5/1.15/krb5-$TERMUX_PKG_VERSION.tar.gz"
TERMUX_PKG_SHA256=437c8831ddd5fde2a993fef425dedb48468109bb3d3261ef838295045a89eb45
TERMUX_PKG_FOLDERNAME="krb5-$TERMUX_PKG_VERSION/src"
TERMUX_PKG_MAINTAINER="Vishal Biswas @vishalbiswas"
TERMUX_PKG_CONFFILES="etc/krb5.conf var/krb5kdc/kdc.conf"
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="--with-readline
--without-system-verto
--with-netlib=-lc
--enable-dns-for-realm
--sbindir=$TERMUX_PREFIX/bin
--with-size-optimizations
--with-system-db
DEFCCNAME=$TERMUX_PREFIX/tmp/krb5cc_%{uid}
DEFKTNAME=$TERMUX_PREFIX/etc/krb5.keytab
DEFCKTNAME=$TERMUX_PREFIX/var/krb5/user/%{euid}/client.keytab
"

termux_step_pre_configure () {
    # cannot test these when cross compiling
    export krb5_cv_attr_constructor_destructor='yes,yes'
    export ac_cv_func_regcomp='yes'
    export ac_cv_printf_positional='yes'

    # bionic doesn't have getpass
    cp "$TERMUX_PKG_BUILDER_DIR/netbsd_getpass.c" "$TERMUX_PKG_SRCDIR/clients/kpasswd/"

    CFLAGS="$CFLAGS -D_PASSWORD_LEN=PASS_MAX"
    LDFLAGS="$LDFLAGS -landroid-glob -llog"
}

termux_step_post_make_install () {
	# Enable logging to STDERR by default
	echo -e "\tdefault = STDERR" >> $TERMUX_PKG_SRCDIR/config-files/krb5.conf

	# Sample KDC config file
	install -dm 700 $TERMUX_PREFIX/var/krb5kdc
	install -pm 600 $TERMUX_PKG_SRCDIR/config-files/kdc.conf $TERMUX_PREFIX/var/krb5kdc/kdc.conf

	# Default configuration file
	install -pm 600 $TERMUX_PKG_SRCDIR/config-files/krb5.conf $TERMUX_PREFIX/etc/krb5.conf

	install -dm 700 $TERMUX_PREFIX/share/aclocal
	install -m 600 $TERMUX_PKG_SRCDIR/util/ac_check_krb5.m4 $TERMUX_PREFIX/share/aclocal
}