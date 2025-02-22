#!/bin/bash
set -e

CCACHE_VERSION=3.7.12
CMAKE_VERSION=3.22.2
CMAKE_MAJOR_VERSION=3.22
GCC_LIBSTDCXX_VERSION=9.3.0
ZLIB_VERSION=1.2.12
OPENSSL_VERSION=1.1.1m
CURL_VERSION=7.81.0
GIT_VERSION=2.35.1
SQLITE_VERSION=3370200
SQLITE_YEAR=2022

# shellcheck source=image/functions.sh
source /hbb_build/functions.sh
# shellcheck source=image/activate_func.sh
source /hbb_build/activate_func.sh

SKIP_INITIALIZE=${SKIP_INITIALIZE:-false}
SKIP_USERS_GROUPS=${SKIP_USERS_GROUPS:-false}
SKIP_TOOLS=${SKIP_TOOLS:-false}
SKIP_LIBS=${SKIP_LIBS:-false}
SKIP_FINALIZE=${SKIP_FINALIZE:-false}

SKIP_CCACHE=${SKIP_CCACHE:-$SKIP_TOOLS}
SKIP_CMAKE=${SKIP_CMAKE:-$SKIP_TOOLS}
SKIP_GIT=${SKIP_GIT:-$SKIP_TOOLS}

SKIP_LIBSTDCXX=${SKIP_LIBSTDCXX:-$SKIP_LIBS}
SKIP_ZLIB=${SKIP_ZLIB:-$SKIP_LIBS}
SKIP_OPENSSL=${SKIP_OPENSSL:-$SKIP_LIBS}
SKIP_CURL=${SKIP_CURL:-$SKIP_LIBS}
SKIP_SQLITE=${SKIP_SQLITE:-$SKIP_LIBS}

MAKE_CONCURRENCY=2
VARIANTS='exe exe_gc_hardened shlib'
export PATH=/hbb/bin:$PATH

#########################

if ! eval_bool "$SKIP_INITIALIZE"; then
	header "Initializing"
	run mkdir -p /hbb /hbb/bin
	run cp /hbb_build/libcheck /hbb/bin/
	run cp /hbb_build/hardening-check /hbb/bin/
	run cp /hbb_build/setuser /hbb/bin/
	run cp /hbb_build/activate_func.sh /hbb/activate_func.sh
	run cp /hbb_build/hbb-activate /hbb/activate
	run cp /hbb_build/activate-exec /hbb/activate-exec

	if ! eval_bool "$SKIP_USERS_GROUPS"; then
		run groupadd -g 9327 builder
		run adduser --uid 9327 --gid 9327 builder
	fi

	for VARIANT in $VARIANTS; do
		run mkdir -p "/hbb_$VARIANT"
		run cp /hbb_build/activate-exec "/hbb_$VARIANT/"
		run cp "/hbb_build/variants/$VARIANT.sh" "/hbb_$VARIANT/activate"
	done

	header "Updating system, installing compiler toolchain"
	run touch /var/lib/rpm/*
	run yum update -y
	run yum install -y tar curl curl-devel m4 autoconf automake libtool pkgconfig openssl-devel \
		file patch bzip2 zlib-devel gettext python-setuptools python-devel \
		epel-release centos-release-scl
	run yum install -y python2-pip "devtoolset-$DEVTOOLSET_VERSION"

	echo "*link_gomp: %{static|static-libgcc|static-libstdc++|static-libgfortran: libgomp.a%s; : -lgomp } %{static: -ldl }" > /opt/rh/devtoolset-9/root/usr/lib/gcc/$(arch)-redhat-linux/9/libgomp.spec
fi


### ccache

if ! eval_bool "$SKIP_CCACHE"; then
	header "Installing ccache $CCACHE_VERSION"
	download_and_extract ccache-$CCACHE_VERSION.tar.gz \
		ccache-$CCACHE_VERSION \
		https://github.com/ccache/ccache/releases/download/v$CCACHE_VERSION/ccache-$CCACHE_VERSION.tar.gz

	(
		activate_holy_build_box_deps_installation_environment
		set_default_cflags
		run ./configure --prefix=/hbb
		run make -j$MAKE_CONCURRENCY install
		run strip --strip-all /hbb/bin/ccache
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf ccache-$CCACHE_VERSION
fi


### CMake

if ! eval_bool "$SKIP_CMAKE"; then
	header "Installing CMake $CMAKE_VERSION"
	download_and_extract cmake-$CMAKE_VERSION.tar.gz \
		cmake-$CMAKE_VERSION \
		https://cmake.org/files/v$CMAKE_MAJOR_VERSION/cmake-$CMAKE_VERSION.tar.gz

	(
		activate_holy_build_box_deps_installation_environment
		set_default_cflags
		run ./configure --prefix=/hbb --no-qt-gui --parallel=$MAKE_CONCURRENCY
		run make -j$MAKE_CONCURRENCY
		run make install
		run strip --strip-all /hbb/bin/cmake /hbb/bin/cpack /hbb/bin/ctest
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf cmake-$CMAKE_VERSION
fi


### Git

if ! eval_bool "$SKIP_GIT"; then
	header "Installing Git $GIT_VERSION"
	download_and_extract git-$GIT_VERSION.tar.gz \
		git-$GIT_VERSION \
		https://www.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.gz

	(
		activate_holy_build_box_deps_installation_environment
		set_default_cflags
		run make configure
		run ./configure --prefix=/hbb --without-tcltk
		run make -j$MAKE_CONCURRENCY
		run make install
		run strip --strip-all /hbb/bin/git
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf git-$GIT_VERSION
fi


## libstdc++

function install_libstdcxx()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing libstdc++ static libraries: $VARIANT"
	download_and_extract gcc-$GCC_LIBSTDCXX_VERSION.tar.gz \
		gcc-$GCC_LIBSTDCXX_VERSION \
		https://ftpmirror.gnu.org/gcc/gcc-$GCC_LIBSTDCXX_VERSION/gcc-$GCC_LIBSTDCXX_VERSION.tar.gz

	(
		# shellcheck source=/dev/null
		source "$PREFIX/activate"
		run rm -rf ../gcc-build
		run mkdir ../gcc-build
		echo "+ Entering /gcc-build"
		cd ../gcc-build

		# shellcheck disable=SC2030
		CFLAGS=$(adjust_optimization_level "$STATICLIB_CFLAGS")
		export CFLAGS

		# The libstdc++ build system has a bug. In order for it to enable C++11 thread
		# support, it checks for gthreads (part of libgcc) support. This is done by checking
		# whether gthr.h can be found and compiled. gthr.h in turn includes gthr-default.h,
		# which is autogenerated at the end of the configure script and placed in include/bits.
		#
		# Therefore we need to run configure twice. The first time to generate include/bits/gthr-default.h,
		# which allows the second configure run to detect gthreads support.
		#
		# https://github.com/FooBarWidget/holy-build-box/issues/19

		# shellcheck disable=SC2030
		CXXFLAGS=$(adjust_optimization_level "$STATICLIB_CXXFLAGS -Iinclude/bits")
		export CXXFLAGS

		../gcc-$GCC_LIBSTDCXX_VERSION/libstdc++-v3/configure \
			--prefix="$PREFIX" --disable-multilib \
			--disable-libstdcxx-visibility --disable-shared
		../gcc-$GCC_LIBSTDCXX_VERSION/libstdc++-v3/configure \
			--prefix="$PREFIX" --disable-multilib \
			--disable-libstdcxx-visibility --disable-shared

		# Assert that C++11 thread support is enabled.
		run grep -q '^#define _GLIBCXX_HAS_GTHREADS 1$' config.h

		run make -j$MAKE_CONCURRENCY
		run mkdir -p "$PREFIX/lib"
		run cp src/.libs/libstdc++.a "$PREFIX/lib/"
		run cp libsupc++/.libs/libsupc++.a "$PREFIX/lib/"
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf gcc-$GCC_LIBSTDCXX_VERSION
	run rm -rf gcc-build
}

if ! eval_bool "$SKIP_LIBSTDCXX"; then
	for VARIANT in $VARIANTS; do
		install_libstdcxx "$VARIANT"
	done
fi


### zlib

function install_zlib()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing zlib $ZLIB_VERSION static libraries: $VARIANT"
	download_and_extract zlib-$ZLIB_VERSION.tar.gz \
		zlib-$ZLIB_VERSION \
		https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz

	(
		# shellcheck source=/dev/null
		source "$PREFIX/activate"
		# shellcheck disable=SC2030,SC2031
		CFLAGS=$(adjust_optimization_level "$STATICLIB_CFLAGS")
		export CFLAGS
		run ./configure --prefix="$PREFIX" --static
		run make -j$MAKE_CONCURRENCY
		run make install
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf zlib-$ZLIB_VERSION
}

if ! eval_bool "$SKIP_ZLIB"; then
	for VARIANT in $VARIANTS; do
		install_zlib "$VARIANT"
	done
fi


### OpenSSL

function install_openssl()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing OpenSSL $OPENSSL_VERSION static libraries: $PREFIX"
	download_and_extract openssl-$OPENSSL_VERSION.tar.gz \
		openssl-$OPENSSL_VERSION \
		https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz

	(
		set -o pipefail

		# shellcheck source=/dev/null
		source "$PREFIX/activate"

		# shellcheck disable=SC2030,SC2001
		CFLAGS=$(adjust_optimization_level "$STATICLIB_CFLAGS")
		export CFLAGS

		# shellcheck disable=SC2086
		run ./config --prefix="$PREFIX" --openssldir="$PREFIX/openssl" \
			threads zlib no-shared no-sse2 $CFLAGS $LDFLAGS
		run make
		run make install_sw
		run strip --strip-all "$PREFIX/bin/openssl"
		if [[ "$VARIANT" = exe_gc_hardened ]]; then
			run hardening-check -b "$PREFIX/bin/openssl"
		fi

		# shellcheck disable=SC2016
		run sed -i 's/^Libs:.*/Libs: -L${libdir} -lcrypto -lz -ldl -lpthread/' "$PREFIX"/lib/pkgconfig/libcrypto.pc
		run sed -i '/^Libs.private:.*/d' "$PREFIX"/lib/pkgconfig/libcrypto.pc
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf openssl-$OPENSSL_VERSION
}

if ! eval_bool "$SKIP_OPENSSL"; then
	for VARIANT in $VARIANTS; do
		install_openssl "$VARIANT"
	done
	run mv /hbb_exe_gc_hardened/bin/openssl /hbb/bin/
	for VARIANT in $VARIANTS; do
		run rm -f "/hbb_$VARIANT/bin/openssl"
	done
fi


### libcurl

function install_curl()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing Curl $CURL_VERSION static libraries: $PREFIX"
	download_and_extract curl-$CURL_VERSION.tar.bz2 \
		curl-$CURL_VERSION \
		https://curl.se/download/curl-$CURL_VERSION.tar.bz2

	(
		# shellcheck source=/dev/null
		source "$PREFIX/activate"
		# shellcheck disable=SC2030,SC2031
		CFLAGS=$(adjust_optimization_level "$STATICLIB_CFLAGS")
		export CFLAGS
		./configure --prefix="$PREFIX" --disable-shared --disable-debug --enable-optimize --disable-werror \
			--disable-curldebug --enable-symbol-hiding --disable-ares --disable-manual --disable-ldap --disable-ldaps \
			--disable-rtsp --disable-dict --disable-ftp --disable-ftps --disable-gopher --disable-imap \
			--disable-imaps --disable-pop3 --disable-pop3s --without-librtmp --disable-smtp --disable-smtps \
			--disable-telnet --disable-tftp --disable-smb --disable-versioned-symbols \
			--without-libidn --without-libssh2 --without-nghttp2 \
			--with-ssl
		run make -j$MAKE_CONCURRENCY
		run make install
		if [[ "$VARIANT" = exe_gc_hardened ]]; then
			run hardening-check -b "$PREFIX/bin/curl"
		fi
		run rm -f "$PREFIX/bin/curl"
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf curl-$CURL_VERSION
}

if ! eval_bool "$SKIP_CURL"; then
	for VARIANT in $VARIANTS; do
		install_curl "$VARIANT"
	done
fi


### SQLite

function install_sqlite()
{
	local VARIANT="$1"
	local PREFIX="/hbb_$VARIANT"

	header "Installing SQLite $SQLITE_VERSION static libraries: $PREFIX"
	download_and_extract sqlite-autoconf-$SQLITE_VERSION.tar.gz \
		sqlite-autoconf-$SQLITE_VERSION \
		https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE_VERSION.tar.gz

	(
		# shellcheck source=/dev/null
		source "$PREFIX/activate"
		# shellcheck disable=SC2031
		CFLAGS=$(adjust_optimization_level "$STATICLIB_CFLAGS")
		# shellcheck disable=SC2031
		CXXFLAGS=$(adjust_optimization_level "$STATICLIB_CXXFLAGS")
		export CFLAGS
		export CXXFLAGS
		run ./configure --prefix="$PREFIX" --enable-static \
			--disable-shared --disable-dynamic-extensions
		run make -j$MAKE_CONCURRENCY
		run make install
		if [[ "$VARIANT" = exe_gc_hardened ]]; then
			run hardening-check -b "$PREFIX/bin/sqlite3"
		fi
		run strip --strip-all "$PREFIX/bin/sqlite3"
	)
	# shellcheck disable=SC2181
	if [[ "$?" != 0 ]]; then false; fi

	echo "Leaving source directory"
	popd >/dev/null
	run rm -rf sqlite-autoconf-$SQLITE_VERSION
}

if ! eval_bool "$SKIP_SQLITE"; then
	for VARIANT in $VARIANTS; do
		install_sqlite "$VARIANT"
	done
	run mv /hbb_exe_gc_hardened/bin/sqlite3 /hbb/bin/
	for VARIANT in $VARIANTS; do
		run rm -f "/hbb_$VARIANT/bin/sqlite3"
	done
fi


### Finalizing

if ! eval_bool "$SKIP_FINALIZE"; then
	header "Finalizing"
	run yum clean -y all
	run rm -rf /hbb/share/doc /hbb/share/man
	run rm -rf /hbb_build /tmp/*
	for VARIANT in $VARIANTS; do
		run rm -rf "/hbb_$VARIANT/share/doc" "/hbb_$VARIANT/share/man"
	done
fi
