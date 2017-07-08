TERMUX_PKG_HOMEPAGE=https://hunspell.github.io
TERMUX_PKG_DESCRIPTION="American english dictionary for hunspell"
TERMUX_PKG_VERSION=2017.03.03
TERMUX_PKG_REVISION=1
TERMUX_PKG_PLATFORM_INDEPENDENT=yes

termux_step_make_install () {
	mkdir -p $TERMUX_PREFIX/share/hunspell/
	# On checksum mismatch the files may have been updated:
	#  https://cgit.freedesktop.org/libreoffice/dictionaries/log/en/en_US.aff
	#  https://cgit.freedesktop.org/libreoffice/dictionaries/log/en/en_US.dic
	# In which case we need to bump version and checksum used.
	termux_download https://cgit.freedesktop.org/libreoffice/dictionaries/plain/en/en_US.aff \
			$TERMUX_PREFIX/share/hunspell/en_US.aff \
			c7a8c4d08c29d237880844b1623099f59092602f189be38ce3912e457ff38bc1
	termux_download https://cgit.freedesktop.org/libreoffice/dictionaries/plain/en/en_US.dic \
			$TERMUX_PREFIX/share/hunspell/en_US.dic \
			8cbce08a66fcd4dd32eadcff2def2653b94863c2e2be1851c6e612558153b076
	touch $TERMUX_PREFIX/share/hunspell/en_US.{aff,dic}
}
