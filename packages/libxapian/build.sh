TERMUX_PKG_HOMEPAGE=https://xapian.org
TERMUX_PKG_DESCRIPTION="Xapian search engine library"
TERMUX_PKG_VERSION=1.4.4
TERMUX_PKG_SRCURL=http://oligarchy.co.uk/xapian/${TERMUX_PKG_VERSION}/xapian-core-${TERMUX_PKG_VERSION}.tar.xz
TERMUX_PKG_SHA256=a6a985a9841a452d75cf2169196b7ca6ebeef27da7c607078cd401ad041732d9
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="ac_cv_c_bigendian=no"