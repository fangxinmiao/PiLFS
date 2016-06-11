#!/bin/bash
#
# PiLFS Build Script LFS-7.9 v1.0, modify by Fangxm
# Builds chapters 6.7 - Raspberry Pi Linux API Headers to 6.70 - Vim
# http://www.intestinate.com/pilfs
#
# Optional parameteres below:

PARALLEL_JOBS=4                 # Number of parallel make jobs, 1 for RPi1 and 4 for RPi2 and RPi3 recommended.
LOCAL_TIMEZONE=Asia/Shanghai    # Use this timezone from /usr/share/zoneinfo/ to set /etc/localtime. See "6.9.2. Configuring Glibc".
GROFF_PAPER_SIZE=A4             # Use this default paper size for Groff. See "6.52. Groff-1.22.3".
INSTALL_OPTIONAL_DOCS=1         # Install optional documentation when given a choice?
INSTALL_ALL_LOCALES=0           # Install all glibc locales? By default only en_US.ISO-8859-1 and en_US.UTF-8 are installed.
INSTALL_SYSTEMD_DEPS=1          # Install optional systemd dependencies? (Attr, Acl, Libcap, Expat, XML::Parser & Intltool)

# End of optional parameters

set -o nounset
set -o errexit

function prebuild_sanity_check {
    if [[ $(whoami) != "root" ]] ; then
        echo "You should be running as root for chapter 6!"
        exit 1
    fi

    if ! [[ -d /sources ]] ; then
        echo "Can't find your sources directory! Did you forget to chroot?"
        exit 1
    fi

    if ! [[ -d /tools ]] ; then
        echo "Can't find your tools directory! Did you forget to chroot?"
        exit 1
    fi
}

function check_tarballs {
    cat sources-list | grep -Ev '^#|^$' | while read tarball ; do
        if ! [[ -f /sources/$tarball ]] ; then
            echo "Can't find /sources/$tarball!"
            exit 1
        fi
    done
}

function timer {
    if [[ $# -eq 0 ]]; then
        echo $(date '+%s')
    else
        local stime=$1
        etime=$(date '+%s')
        if [[ -z "$stime" ]]; then stime=$etime; fi
        dt=$((etime - stime))
        ds=$((dt % 60))
        dm=$(((dt / 60) % 60))
        dh=$((dt / 3600))
        printf '%02d:%02d:%02d' $dh $dm $ds
    fi
}

function make_sure {
    if [[ $(cat /proc/swaps | wc -l) == 1 ]] ; then
        echo -e "\nYou are almost certainly going to want to add some swap space before building!"
        echo -e "(See http://www.intestinate.com/pilfs/beyond.html#addswap for instructions)"
        echo -e "Continue without swap?"
        select yn in "Yes" "No"; do
            case $yn in
                Yes ) break;;
                No ) exit;;
            esac
        done
    fi
    
    echo -e "\nThis is your last chance to quit before we start building... continue?"
    echo "(Note that if anything goes wrong during the build, the script will abort mission)"
    select yn in "Yes" "No"; do
        case $yn in
            Yes ) break;;
            No ) exit;;
        esac
    done
}

total_time=$(timer)

function build_linux_api_headers() {
    cd /sources && echo $2-$1
    if ! [[ -d /sources/linux-rpi-$1 ]] ; then
        tar -xf rpi-$1.tar.gz
    fi
    cd linux-rpi-$1

    make mrproper
    make INSTALL_HDR_PATH=dest headers_install
    find dest/include \( -name .install -o -name ..install.cmd \) -delete
    cp -rv dest/include/* /usr/include
}
    
function build_manpages() {
    cd /sources && echo $2-$1
    tar -xf man-pages-$1.tar.xz && cd man-pages-$1

    make install

    rm -rf /sources/man-pages-$1
}
    
function build_glibc() {
    cd /sources && echo $2-$1
    tar -xf glibc-$1.tar.xz && cd glibc-$1

    patch -Np1 -i ../glibc-$1-fhs-1.patch
    mkdir build && cd build

    ../configure --prefix=/usr \
        --disable-profile      \
        --enable-kernel=2.6.32 \
        --enable-obsolete-rpc
    make -j $PARALLEL_JOBS
    touch /etc/ld.so.conf
    make install
    cp -v ../nscd/nscd.conf /etc/nscd.conf
    mkdir -pv /var/cache/nscd

    if [[ $INSTALL_ALL_LOCALES = 1 ]] ; then
        make localedata/install-locales
    else
        mkdir -pv /usr/lib/locale
        localedef -i en_US -f ISO-8859-1 en_US
        localedef -i en_US -f UTF-8 en_US.UTF-8
        localedef -i zh_CN -f GB18030 zh_CN.GB18030
        localedef -i zh_CN -f UTF-8 zh_CN.UTF-8
    fi

cat > /etc/nsswitch.conf << "EOF"
# Begin /etc/nsswitch.conf

passwd: files
group: files
shadow: files

hosts: files dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
EOF

    tar -zxf ../../tzdata2016a.tar.gz
    ZONEINFO=/usr/share/zoneinfo
    mkdir -pv $ZONEINFO/{posix,right}

    for tz in etcetera southamerica northamerica europe africa antarctica  \
              asia australasia backward pacificnew systemv; do
        zic -L /dev/null   -d $ZONEINFO       -y "sh yearistype.sh" ${tz}
        zic -L /dev/null   -d $ZONEINFO/posix -y "sh yearistype.sh" ${tz}
        zic -L leapseconds -d $ZONEINFO/right -y "sh yearistype.sh" ${tz}
    done

    cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
    zic -d $ZONEINFO -p America/New_York
    unset ZONEINFO

    if ! [[ -f /usr/share/zoneinfo/$LOCAL_TIMEZONE ]] ; then
        echo "Seems like your timezone won't work out. Defaulting to London."
        echo "Either fix it yourself later or consider moving there :)"
        cp -v /usr/share/zoneinfo/Europe/London /etc/localtime
    else
        cp -v /usr/share/zoneinfo/$LOCAL_TIMEZONE /etc/localtime
    fi

cat > /etc/ld.so.conf << "EOF"
# Begin /etc/ld.so.conf

/usr/local/lib
/opt/lib

# Add an include directory
include /etc/ld.so.conf.d/*.conf
EOF
    mkdir -pv /etc/ld.so.conf.d

    # Compatibility symlink for non ld-linux-armhf awareness
    ln -sv ld-$1.so /lib/ld-linux.so.3

    rm -rf /sources/glibc-$1

    # Adjusting the Toolchain
    mv -v /tools/bin/{ld,ld-old}
    mv -v /tools/$(gcc -dumpmachine)/bin/{ld,ld-old}
    mv -v /tools/bin/{ld-new,ld}
    ln -sv /tools/bin/ld /tools/$(gcc -dumpmachine)/bin/ld
    gcc -dumpspecs | sed -e 's@/tools@@g'                   \
        -e '/\*startfile_prefix_spec:/{n;s@.*@/usr/lib/ @}' \
        -e '/\*cpp:/{n;s@$@ -isystem /usr/include@}' >      \
        `dirname $(gcc --print-libgcc-file-name)`/specs

    # It is imperative at this point to ensure that the basic functions
    # (compiling and linking) of the adjusted toolchain are working as
    # expected. To do this, perform the following sanity checks:
    echo 'main(){}' > dummy.c
    cc dummy.c -v -Wl,--verbose &> dummy.log
    result=`echo \`readelf -l a.out | grep ': /lib'\``
    expect='[Requesting program interpreter: /lib/ld-linux-armhf.so.3]'
    if [ "$result" != "$expect" ]; then
        echo 'Build glibc failed [1]'
        exit 1
    fi

    # Now make sure that we're setup to use the current startfiles:
    result=`echo \`grep -o '/usr/lib.*/crt[1in].*succeeded' dummy.log\``
    expect='/usr/lib/crt1.o succeeded /usr/lib/crti.o succeeded /usr/lib/crtn.o succeeded'
    if [ "$result" != "$expect" ]; then
        echo 'Build glibc failed [2]'
        exit 2
    fi

    # Verify that the compiler is searching for the correct haader files:
    result=`echo \`grep -B1 '^ /usr/include' dummy.log\``
    expect='#include <...> search starts here: /usr/include'
    if [ "$result" != "$expect" ]; then
        echo 'Build glibc failed [3]'
        exit 3
    fi

    # Next make sure that we're using the corrent libc:
    result=`echo \`grep "/lib.*/libc.so.6 " dummy.log\``
    case $(uname -m) in
        x86_64)
            expect='attempt to open /lib64/libc.so.6 succeeded'
            ;;
        *)
            expect='attempt to open /lib/libc.so.6 succeeded'
            ;;
    esac
    if [ "$result" != "$expect" ]; then
        echo 'Build glibc failed [5]'
        exit 5
    fi

    # Lastly, make sure GCC is using the corrent dynamic linker:
    result=`echo \`grep found dummy.log\``
    case $(uname -m) in
        x86_64)
            expect='found ld-linux-x86-64.so.2 at /lib64/ld-linux-x86-64.so.2'
            ;;
        arm*)
            expect='found ld-linux-armhf.so.3 at /lib/ld-linux-armhf.so.3'
            ;;
        *)
            expect='found ld-linux.so.2 at /lib/ld-linux.so.2'
            ;;
    esac
    if [ "$result" != "$expect" ]; then
        echo 'Build glibc failed [6]'
        exit 6
    fi

    rm -fv dummy.c a.out dummy.log
    echo "check success"
}

function build_zlib() {
    cd /sources && echo $2-$1
    tar -xf zlib-$1.tar.xz && cd zlib-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install
    mv -v /usr/lib/libz.so.* /lib
    ln -sfv ../../lib/$(readlink /usr/lib/libz.so) /usr/lib/libz.so

    rm -rf /sources/zlib-$1
}

function build_file() {
    cd /sources && echo $2-$1
    tar -xf file-$1.tar.gz && cd file-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/file-$1
}
    
function build_binutils() {
    cd /sources && echo $2-$1
    tar -xf binutils-$1.tar.bz2 && cd binutils-$1

    patch -Np1 -i ../binutils-$1-upstream_fix-2.patch
    mkdir build && cd build

    ../configure --prefix=/usr \
        --enable-shared \
        --disable-werror
    make -j $PARALLEL_JOBS tooldir=/usr
    make tooldir=/usr install

    rm -rf /sources/binutils-$1
}
    
function build_gmp() {
    cd /sources && echo $2-$1
    tar -xf gmp-$1.tar.xz && cd gmp-$1

    ./configure --prefix=/usr \
        --enable-cxx \
        --disable-static \
        --docdir=/usr/share/doc/gmp-$1
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        make html
        make install-html
    fi

    rm -rf /sources/gmp-$1
}
    
function build_mpfr() {
    cd /sources && echo $2-$1
    tar -xf mpfr-$1.tar.xz && cd mpfr-$1

    ./configure  --prefix=/usr        \
                 --disable-static     \
                 --enable-thread-safe \
                 --docdir=/usr/share/doc/mpfr-$1
    make -j $PARALLEL_JOBS
    make install
    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        make html
        make install-html
    fi

    rm -rf /sources/mpfr-$1
}
    
function build_mpc() {
    cd /sources && echo $2-$1
    tar -xf mpc-$1.tar.gz && cd mpc-$1

    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/mpc-$1
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        make html
        make install-html
    fi

    rm -rf /sources/mpc-$1
}
    
function build_gcc() {
    cd /sources && echo $2-$1
    tar -xf gcc-$1.tar.bz2 && cd gcc-$1

    case $(uname -m) in
      armv6l) patch -Np1 -i ../gcc-$1-rpi1-cpu-default.patch ;;
      armv7l) case $(sed -n '/^Revision/s/^.*: \(.*\)/\1/p' < /proc/cpuinfo) in
        a02082|a22082) patch -Np1 -i ../gcc-$1-rpi3-cpu-default.patch ;;
        *) patch -Np1 -i ../gcc-$1-rpi2-cpu-default.patch ;;
        esac
      ;;
    esac

    mkdir build && cd build

    SED=sed \
    ../configure --prefix=/usr   \
        --enable-languages=c,c++ \
        --disable-multilib       \
        --disable-bootstrap      \
        --with-system-zlib
    make
    make install

    ln -sv ../usr/bin/cpp /lib
    ln -sv gcc /usr/bin/cc
    install -v -dm755 /usr/lib/bfd-plugins
    ln -sfv ../../libexec/gcc/$(gcc -dumpmachine)/$1/liblto_plugin.so \
        /usr/lib/bfd-plugins/
    mkdir -pv /usr/share/gdb/auto-load/usr/lib
    mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib

    rm -rf /sources/gcc-$1
}
    
function build_bzip2() {
    cd /sources && echo $2-$1
    tar -xf bzip2-$1.tar.gz && cd bzip2-$1

    patch -Np1 -i ../bzip2-$1-install_docs-1.patch
    sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
    sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile

    make -j $PARALLEL_JOBS -f Makefile-libbz2_so
    make clean
    make -j $PARALLEL_JOBS
    make PREFIX=/usr install

    cp -v bzip2-shared /bin/bzip2
    cp -av libbz2.so* /lib
    ln -sv ../../lib/libbz2.so.1.0 /usr/lib/libbz2.so
    rm -v /usr/bin/{bunzip2,bzcat,bzip2}
    ln -sv bzip2 /bin/bunzip2
    ln -sv bzip2 /bin/bzcat

    rm -rf /sources/bzip2-$1
}
    
function build_pkgconfig() {
    cd /sources && echo $2-$1
    tar -xf pkg-config-$1.tar.gz && cd pkg-config-$1

    ./configure --prefix=/usr \
        --with-internal-glib  \
        --disable-host-tool   \
        --docdir=/usr/share/doc/pkg-config-$1
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/pkg-config-$1
}

function build_ncurses() {
    cd /sources && echo $2-$1
    tar -xf ncurses-$1.tar.gz && cd ncurses-$1

    sed -i '/LIBTOOL_INSTALL/d' c++/Makefile.in

    ./configure --prefix=/usr   \
        --mandir=/usr/share/man \
        --with-shared           \
        --without-debug         \
        --without-normal        \
        --enable-pc-files       \
        --enable-widec
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/lib/libncursesw.so.6* /lib
    ln -sfv ../../lib/$(readlink /usr/lib/libncursesw.so) /usr/lib/libncursesw.so
    for lib in ncurses form panel menu ; do
        rm -vf                    /usr/lib/lib${lib}.so
        echo "INPUT(-l${lib}w)" > /usr/lib/lib${lib}.so
        ln -sfv ${lib}w.pc        /usr/lib/pkgconfig/${lib}.pc
    done
    rm -vf                     /usr/lib/libcursesw.so
    echo "INPUT(-lncursesw)" > /usr/lib/libcursesw.so
    ln -sfv libncurses.so      /usr/lib/libcurses.so
    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        mkdir -v       /usr/share/doc/ncurses-$1
        cp -v -R doc/* /usr/share/doc/ncurses-$1
    fi

    rm -rf /sources/ncurses-$1
}
    
function build_attr() {
    if [[ $INSTALL_SYSTEMD_DEPS = 1 ]] ; then
    cd /sources && echo $2-$1
    tar -xf attr-$1.src.tar.gz && cd attr-$1

    sed -i -e 's|/@pkg_name@|&-@pkg_version@|' include/builddefs.in
    sed -i -e "/SUBDIRS/s|man[25]||g" man/Makefile

    ./configure --prefix=/usr \
        --bindir=/bin \
        --disable-static
    make -j $PARALLEL_JOBS
    make install install-dev install-lib

    chmod -v 755 /usr/lib/libattr.so
    mv -v /usr/lib/libattr.so.* /lib
    ln -sfv ../../lib/$(readlink /usr/lib/libattr.so) /usr/lib/libattr.so

    rm -rf /sources/attr-$1
    fi
}
    
function build_acl() {
    if [[ $INSTALL_SYSTEMD_DEPS = 1 ]] ; then
    cd /sources && echo $2-$1
    tar -xf acl-$1.src.tar.gz && cd acl-$1

    sed -i -e 's|/@pkg_name@|&-@pkg_version@|' include/builddefs.in
    sed -i "s:| sed.*::g" test/{sbits-restore,cp,misc}.test
    sed -i -e "/TABS-1;/a if (x > (TABS-1)) x = (TABS-1);" \
        libacl/__acl_to_any_text.c

    ./configure --prefix=/usr \
        --bindir=/bin \
        --disable-static \
        --libexecdir=/usr/lib
    make -j $PARALLEL_JOBS
    make install install-dev install-lib

    chmod -v 755 /usr/lib/libacl.so
    mv -v /usr/lib/libacl.so.* /lib
    ln -sfv ../../lib/$(readlink /usr/lib/libacl.so) /usr/lib/libacl.so

    rm -rf /sources/acl-$1
    fi
}
    
function build_libcap() {
    if [[ $INSTALL_SYSTEMD_DEPS = 1 ]] ; then
    cd /sources && echo $2-$1
    tar -xf libcap-$1.tar.xz && cd libcap-$1

    sed -i '/install.*STALIBNAME/d' libcap/Makefile

    make -j $PARALLEL_JOBS
    make RAISE_SETFCAP=no prefix=/usr install

    chmod -v 755 /usr/lib/libcap.so
    mv -v /usr/lib/libcap.so.* /lib
    ln -sfv ../../lib/$(readlink /usr/lib/libcap.so) /usr/lib/libcap.so

    rm -rf /sources/libcap-$1
    fi
}
    
function build_sed() {
    cd /sources && echo $2-$1
    tar -xf sed-$1.tar.bz2 && cd sed-$1

    ./configure --prefix=/usr --bindir=/bin --htmldir=/usr/share/doc/sed-$1
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        make html
        make -C doc install-html
    fi

    rm -rf /sources/sed-$1
}

function build_shadow() {
    cd /sources && echo $2-$1
    tar -xf shadow-$1.tar.xz && cd shadow-$1

    sed -i 's/groups$(EXEEXT) //' src/Makefile.in

    find man -name Makefile.in -exec sed -i 's/groups\.1 / /'   {} \;
    find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
    find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;
    sed -i -e 's@#ENCRYPT_METHOD DES@ENCRYPT_METHOD SHA512@' \
           -e 's@/var/spool/mail@/var/mail@' etc/login.defs
    sed -i 's/1000/999/' etc/useradd

    ./configure --sysconfdir=/etc --with-group-name-max-length=32
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/bin/passwd /bin

    pwconv
    grpconv

    sed -i 's/yes/no/' /etc/default/useradd

    # passwd root
    # Root password will be set at the end of the script to prevent a stop here

    rm -rf /sources/shadow-$1
}
    
function build_psmisc() {
    cd /sources && echo $2-$1
    tar -xf psmisc-$1.tar.gz && cd psmisc-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/bin/fuser   /bin
    mv -v /usr/bin/killall /bin

    rm -rf /sources/psmisc-$1
}

function build_procpsng() {
    cd /sources && echo $2-$1
    tar -xf procps-ng-$1.tar.xz && cd procps-ng-$1

    ./configure --prefix=/usr \
        --exec-prefix= \
        --libdir=/usr/lib \
        --docdir=/usr/share/doc/procps-ng-$1 \
        --disable-static \
        --disable-kill
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/lib/libprocps.so.* /lib
    ln -sfv ../../lib/$(readlink /usr/lib/libprocps.so) /usr/lib/libprocps.so

    rm -rf /sources/procps-ng-$1
}

function build_e2fsprogs() {
    cd /sources && echo $2-$1
    tar -xf e2fsprogs-$1.tar.gz && cd e2fsprogs-$1
    mkdir build && cd build

    LIBS=-L/tools/lib                    \
    CFLAGS=-I/tools/include              \
    PKG_CONFIG_PATH=/tools/lib/pkgconfig \
    ../configure --prefix=/usr           \
                 --bindir=/bin           \
                 --with-root-prefix=""   \
                 --enable-elf-shlibs     \
                 --disable-libblkid      \
                 --disable-libuuid       \
                 --disable-uuidd         \
                 --disable-fsck
    make -j $PARALLEL_JOBS
    make install
    make install-libs
    chmod -v u+w /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        gunzip -v /usr/share/info/libext2fs.info.gz
        install-info --dir-file=/usr/share/info/dir /usr/share/info/libext2fs.info
        makeinfo -o      doc/com_err.info ../lib/et/com_err.texinfo
        install -v -m644 doc/com_err.info /usr/share/info
        install-info --dir-file=/usr/share/info/dir /usr/share/info/com_err.info
    fi

    rm -rf /sources/e2fsprogs-$1
}

function build_ianaetc() {
    cd /sources && echo $2-$1
    tar -xf iana-etc-$1.tar.bz2 && cd iana-etc-$1

    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/iana-etc-$1
}
    
function build_m4() {
    cd /sources && echo $2-$1
    tar -xf m4-$1.tar.xz && cd m4-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/m4-$1
}
    
function build_bison() {
    cd /sources && echo $2-$1
    tar -xf bison-$1.tar.xz && cd bison-$1

    ./configure --prefix=/usr --docdir=/usr/share/doc/bison-$1
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/bison-$1
}
    
function build_flex() {
    cd /sources && echo $2-$1
    tar -xf flex-$1.tar.xz && cd flex-$1

    ./configure --prefix=/usr --docdir=/usr/share/doc/flex-$1
    make -j $PARALLEL_JOBS
    make install

    ln -sv flex /usr/bin/lex

    rm -rf /sources/flex-$1
}
    
function build_grep() {
    cd /sources && echo $2-$1
    tar -xf grep-$1.tar.xz && cd grep-$1

    ./configure --prefix=/usr --bindir=/bin
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/grep-${1}
}
    
function build_readline() {
    cd /sources && echo $2-$1
    tar -xf readline-$1.tar.gz && cd readline-$1

    patch -Np1 -i ../readline-$1-upstream_fixes-3.patch
    sed -i '/MV.*old/d' Makefile.in
    sed -i '/{OLDSUFF}/c:' support/shlib-install

    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/readline-$1
    make -j $PARALLEL_JOBS SHLIB_LIBS=-lncurses
    make SHLIB_LIBS=-lncurses install

    mv -v /usr/lib/lib{readline,history}.so.* /lib
    ln -sfv ../../lib/$(readlink /usr/lib/libreadline.so) /usr/lib/libreadline.so
    ln -sfv ../../lib/$(readlink /usr/lib/libhistory.so ) /usr/lib/libhistory.so

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        install -v -m644 doc/*.{ps,pdf,html,dvi} /usr/share/doc/readline-$1
    fi

    rm -rf /sources/readline-$1
}

function build_bash() {
    cd /sources && echo $2-$1
    tar -xf bash-$1.tar.gz && cd bash-$1

    patch -Np1 -i ../bash-$1-upstream_fixes-3.patch

    ./configure --prefix=/usr \
        --docdir=/usr/share/doc/bash-$1 \
        --without-bash-malloc \
        --with-installed-readline
    make -j $PARALLEL_JOBS
    make install

    mv -vf /usr/bin/bash /bin

    # exec /bin/bash --login +h
    # Don't know of a good way to keep running the script after entering bash here.

    rm -rf /sources/bash-$1
}
    
function build_bc() {
    cd /sources && echo $2-$1
    tar -xf bc-$1.tar.bz2 && cd bc-$1

    patch -Np1 -i ../bc-$1-memory_leak-1.patch

    ./configure --prefix=/usr \
        --with-readline \
        --mandir=/usr/share/man \
        --infodir=/usr/share/info
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/bc-$1
}
    
function build_libtool() {
    cd /sources && echo $2-$1
    tar -xf libtool-$1.tar.xz && cd libtool-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/libtool-$1
}
    
function build_gdbm() {
    cd /sources && echo $2-$1
    tar -xf gdbm-$1.tar.gz && cd gdbm-$1

    ./configure --prefix=/usr \
        --disable-static \
        --enable-libgdbm-compat
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/gdbm-$1
}
    
function build_expat() {
    if [[ $INSTALL_SYSTEMD_DEPS = 1 ]] ; then
    cd /sources && echo $2-$1
    tar -xf expat-$1.tar.gz && cd expat-$1

    ./configure --prefix=/usr --disable-static
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        install -v -dm755 /usr/share/doc/expat-$1
        install -v -m644 doc/*.{html,png,css} /usr/share/doc/expat-$1
    fi

    rm -rf /sources/expat-$1
    fi
}

function build_inetutils() {
    cd /sources && echo $2-$1
    tar -xf inetutils-$1.tar.xz && cd inetutils-$1

    ./configure --prefix=/usr \
        --localstatedir=/var  \
        --disable-logger      \
        --disable-whois       \
        --disable-rcp         \
        --disable-rexec       \
        --disable-rlogin      \
        --disable-rsh         \
        --disable-servers
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/bin/{hostname,ping,ping6,traceroute} /bin
    mv -v /usr/bin/ifconfig /sbin

    rm -rf /sources/inetutils-$1
}

function build_perl() {
    cd /sources && echo $2-$1
    tar -xf perl-$1.tar.bz2 && cd perl-$1

    echo "127.0.0.1 localhost $(hostname)" > /etc/hosts

    export BUILD_ZLIB=False
    export BUILD_BZIP2=0

    sh Configure -des -Dprefix=/usr   \
        -Dvendorprefix=/usr           \
        -Dman1dir=/usr/share/man/man1 \
        -Dman3dir=/usr/share/man/man3 \
        -Dpager="/usr/bin/less -isR"  \
        -Duseshrplib
    make -j $PARALLEL_JOBS
    make install

    unset BUILD_ZLIB BUILD_BZIP2

    rm -rf /sources/perl-$1
}
    
function build_xmlparser() {
    if [[ $INSTALL_SYSTEMD_DEPS = 1 ]] ; then
    cd /sources && echo $2-$1
    tar -xf XML-Parser-$1.tar.gz && cd XML-Parser-$1

    perl Makefile.PL
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/XML-Parser-$1
    fi
}
    
function build_autoconf() {
    cd /sources && echo $2-$1
    tar -xf autoconf-$1.tar.xz && cd autoconf-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/autoconf-$1
}
    
function build_automake() {
    cd /sources && echo $2-$1
    tar -xf automake-$1.tar.xz && cd automake-$1

    sed -i 's:/\\\${:/\\\$\\{:' bin/automake.in

    ./configure --prefix=/usr --docdir=/usr/share/doc/automake-$1
    make -j $PARALLEL_JOBS
    make install
    
    rm -rf /sources/automake-$1
}

function build_coreutils() {
    cd /sources && echo $2-$1
    tar -xf coreutils-$1.tar.xz && cd coreutils-$1

    patch -Np1 -i ../coreutils-$1-i18n-2.patch

    FORCE_UNSAFE_CONFIGURE=1 \
    ./configure --prefix=/usr \
        --enable-no-install-program=kill,uptime
    FORCE_UNSAFE_CONFIGURE=1 make -j $PARALLEL_JOBS
    make install

    mv -v /usr/bin/{cat,chgrp,chmod,chown,cp,date,dd,df,echo} /bin
    mv -v /usr/bin/{false,ln,ls,mkdir,mknod,mv,pwd,rm} /bin

    # Found a problem here where the moved mv binary from the line above
    # can't be found by the next line. Inserting a sync as a workaround.
    sync

    mv -v /usr/bin/{rmdir,stty,sync,true,uname} /bin
    mv -v /usr/bin/chroot /usr/sbin
    mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8
    sed -i s/\"1\"/\"8\"/1 /usr/share/man/man8/chroot.8
    mv -v /usr/bin/{head,sleep,nice,test,[} /bin

    rm -rf /sources/coreutils-$1
}

function build_diffutils() {
    cd /sources && echo $2-$1
    tar -xf diffutils-$1.tar.xz && cd diffutils-$1

    sed -i 's:= @mkdir_p@:= /bin/mkdir -p:' po/Makefile.in.in

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/diffutils-$1
}
    
function build_gawk() {
    cd /sources && echo $2-$1
    tar -xf gawk-$1.tar.xz && cd gawk-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        mkdir -v /usr/share/doc/gawk-$1
        cp -v doc/{awkforai.txt,*.{eps,pdf,jpg}} /usr/share/doc/gawk-$1
    fi

    rm -rf /sources/gawk-$1
}

function build_findutils() {
    cd /sources && echo $2-$1
    tar -xf findutils-$1.tar.gz && cd findutils-$1

    ./configure --prefix=/usr --localstatedir=/var/lib/locate
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/bin/find /bin
    sed -i 's/find:=${BINDIR}/find:=\/bin/' /usr/bin/updatedb

    rm -rf /sources/findutils-$1
}
    
function build_gettext() {
    cd /sources && echo $2-$1
    tar -xf gettext-$1.tar.xz && cd gettext-$1

    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/gettext-$1
    make -j $PARALLEL_JOBS
    make install

    chmod -v 0755 /usr/lib/preloadable_libintl.so

    rm -rf /sources/gettext-$1
}

function build_intltool() {
    if [[ $INSTALL_SYSTEMD_DEPS = 1 ]] ; then
    cd /sources && echo $2-$1
    tar -xf intltool-$1.tar.gz && cd intltool-$1

    sed -i 's:\\\${:\\\$\\{:' intltool-update.in

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        install -v -Dm644 doc/I18N-HOWTO \
            /usr/share/doc/intltool-$1/I18N-HOWTO
    fi

    rm -rf /sources/intltool-$1
    fi
}
    
function build_gperf() {
    cd /sources && echo $2-$1
    tar -xf gperf-$1.tar.gz && cd gperf-$1

    ./configure --prefix=/usr --docdir=/usr/share/doc/gperf-$1
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/gperf-$1
}
    
function build_groff() {
    cd /sources && echo $2-$1
    tar -xf groff-$1.tar.gz && cd groff-$1

    PAGE=$GROFF_PAPER_SIZE ./configure --prefix=/usr

    # Groff doesn't like parallel jobs
    make
    make install

    rm -rf /sources/groff-$1
}

function build_xz() {
    cd /sources && echo $2-$1
    tar -xf xz-$1.tar.xz && cd xz-$1

    sed -e '/mf\.buffer = NULL/a next->coder->mf.size = 0;' \
        -i src/liblzma/lz/lz_encoder.c

    ./configure --prefix=/usr \
        --disable-static \
        --docdir=/usr/share/doc/xz-$1
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/bin/{lzma,unlzma,lzcat,xz,unxz,xzcat} /bin
    mv -v /usr/lib/liblzma.so.* /lib
    ln -svf ../../lib/$(readlink /usr/lib/liblzma.so) /usr/lib/liblzma.so

    rm -rf /sources/xz-$1
}

function build_grub() {
    echo $2
    echo "# We don't use GRUB on ARM"
}

function build_less() {
    cd /sources && echo $2-$1
    tar -xf less-$1.tar.gz && cd less-$1

    ./configure --prefix=/usr --sysconfdir=/etc
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/less-$1
}
    
function build_gzip() {
    cd /sources && echo $2-$1
    tar -xf gzip-$1.tar.xz && cd gzip-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    mv -v /usr/bin/gzip /bin

    rm -rf /sources/gzip-$1
}
    
function build_iproute2() {
    cd /sources && echo $2-$1
    tar -xf iproute2-$1.tar.xz && cd iproute2-$1

    sed -i /ARPD/d Makefile
    sed -i 's/arpd.8//' man/man8/Makefile
    rm -v doc/arpd.sgml

    make -j $PARALLEL_JOBS
    make DOCDIR=/usr/share/doc/iproute2-$1 install

    rm -rf /sources/iproute2-$1
}
    
function build_kbd() {
    cd /sources && echo $2-$1
    tar -xf kbd-$1.tar.xz && cd kbd-$1

    patch -Np1 -i ../kbd-$1-backspace-1.patch
    sed -i 's/\(RESIZECONS_PROGS=\)yes/\1no/g' configure
    sed -i 's/resizecons.8 //' docs/man/man8/Makefile.in

    PKG_CONFIG_PATH=/tools/lib/pkgconfig \
    ./configure --prefix=/usr --disable-vlock
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        mkdir -v /usr/share/doc/kbd-$1
        cp -R -v docs/doc/* /usr/share/doc/kbd-$1
    fi

    rm -rf /sources/kbd-$1
}

function build_kmod() {
    cd /sources && echo $2-$1
    tar -xf kmod-$1.tar.xz && cd kmod-$1

    ./configure --prefix=/usr  \
        --bindir=/bin          \
        --sysconfdir=/etc      \
        --with-rootlibdir=/lib \
        --with-xz              \
        --with-zlib
    make -j $PARALLEL_JOBS
    make install

    for target in depmod insmod lsmod modinfo modprobe rmmod; do
      ln -sv ../bin/kmod /sbin/$target
    done
    ln -sv kmod /bin/lsmod

    rm -rf /sources/kmod-$1
}
    
function build_libpipeline() {
    cd /sources && echo $2-$1
    tar -xf libpipeline-$1.tar.gz && cd libpipeline-$1

    PKG_CONFIG_PATH=/tools/lib/pkgconfig ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/libpipeline-$1
}
    
function build_make() {
    cd /sources && echo $2-$1
    tar -xf make-$1.tar.bz2 && cd make-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/make-$1
}

function build_patch() {
    cd /sources && echo $2-$1
    tar -xf patch-$1.tar.xz && cd patch-$1

    ./configure --prefix=/usr
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/patch-$1
}
    
function build_sysklogd() {
    cd /sources && echo $2-$1
    tar -xf sysklogd-$1.tar.gz && cd sysklogd-$1

    sed -i '/Error loading kernel symbols/{n;n;d}' ksym_mod.c
    make -j $PARALLEL_JOBS
    make BINDIR=/sbin install

cat > /etc/syslog.conf << "EOF"
# Begin /etc/syslog.conf

auth,authpriv.* -/var/log/auth.log
daemon.* -/var/log/daemon.log
kern.* -/var/log/kern.log
mail.* -/var/log/mail.log
user.* -/var/log/user.log
*.emerg *

# End /etc/syslog.conf
EOF

    rm -rf /sources/sysklogd-$1
}
    
function build_sysvinit() {
    cd /sources && echo $2-$1
    tar -xf sysvinit-$1.tar.bz2 && cd sysvinit-$1

    patch -Np1 -i ../sysvinit-$1-consolidated-1.patch

    make -j $PARALLEL_JOBS -C src
    make -C src install

    rm -rf /sources/sysvinit-$1
}

function build_tar() {
    cd /sources && echo $2-$1
    tar -xf tar-$1.tar.xz && cd tar-$1

    FORCE_UNSAFE_CONFIGURE=1 \
    ./configure --prefix=/usr \
        --bindir=/bin
    make -j $PARALLEL_JOBS
    make install

    if [[ $INSTALL_OPTIONAL_DOCS = 1 ]] ; then
        make -C doc install-html docdir=/usr/share/doc/tar-$1
    fi

    rm -rf /sources/tar-$1
}
    
function build_texinfo() {
    cd /sources && echo $2-$1
    tar -xf texinfo-$1.tar.xz && cd texinfo-$1

    ./configure --prefix=/usr --disable-static
    make -j $PARALLEL_JOBS
    make install

    # I don't know anybody who wants this... prove me wrong!
    # make TEXMF=/usr/share/texmf install-tex

    rm -rf /sources/texinfo-$1
}
    
function build_eudev() {
    cd /sources && echo $2-$1
    tar -xf eudev-$1.tar.gz && cd eudev-$1

    sed -r -i 's|/usr(/bin/test)|\1|' test/udev-test.pl

cat > config.cache << "EOF"
HAVE_BLKID=1
BLKID_LIBS="-lblkid"
BLKID_CFLAGS="-I/tools/include"
EOF

    ./configure --prefix=/usr   \
        --bindir=/sbin          \
        --sbindir=/sbin         \
        --libdir=/usr/lib       \
        --sysconfdir=/etc       \
        --libexecdir=/lib       \
        --with-rootprefix=      \
        --with-rootlibdir=/lib  \
        --enable-manpages       \
        --disable-static        \
        --config-cache
    LIBRARY_PATH=/tools/lib make -j $PARALLEL_JOBS
    mkdir -pv /lib/udev/rules.d
    mkdir -pv /etc/udev/rules.d
    make LD_LIBRARY_PATH=/tools/lib install

    tar -xf ../udev-lfs-20140408.tar.bz2
    make -f udev-lfs-20140408/Makefile.lfs install
    LD_LIBRARY_PATH=/tools/lib udevadm hwdb --update

    rm -rf /sources/eudev-$1
}
    
function build_utillinux() {
    cd /sources && echo $2-$1
    tar -xf util-linux-$1.tar.xz && cd util-linux-$1

    mkdir -pv /var/lib/hwclock

    ./configure ADJTIME_PATH=/var/lib/hwclock/adjtime \
        --docdir=/usr/share/doc/util-linux-$1 \
        --disable-chfn-chsh  \
        --disable-login      \
        --disable-nologin    \
        --disable-su         \
        --disable-setpriv    \
        --disable-runuser    \
        --disable-pylibmount \
        --disable-static     \
        --without-python     \
        --without-systemd    \
        --without-systemdsystemunitdir
    make
    make install

    rm -rf /sources/util-linux-$1
}
    
function build_mandb() {
    cd /sources && echo $2-$1
    tar -xf man-db-$1.tar.xz && cd man-db-$1

    ./configure --prefix=/usr             \
        --docdir=/usr/share/doc/man-db-$1 \
        --sysconfdir=/etc                 \
        --disable-setuid                  \
        --with-browser=/usr/bin/lynx      \
        --with-vgrind=/usr/bin/vgrind     \
        --with-grap=/usr/bin/grap
    make -j $PARALLEL_JOBS
    make install

    rm -rf /sources/man-db-$1
}
    
function build_vim() {
    cd /sources && echo $2-$1

    # "7.4" ==> major: 7, minor: 4
    major=${1%%.*}
    minor=${1##*.}
    srcdir=vim${major}${minor}
    tar -xf vim-$1.tar.bz2 && cd $srcdir

    echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h

    ./configure --prefix=/usr \
        --enable-multibyte \
        --enable-cscope \
        --enable-gui=no \
        --enable-pythoninterp \
        --enable-perlinterp \
        --enable-luainterp
    make -j $PARALLEL_JOBS
    make install

    ln -sv vim /usr/bin/vi
    for L in /usr/share/man/{,*/}man1/vim.1; do
        ln -sv vim.1 $(dirname $L)/vi.1
    done
    ln -sv ../vim/$srcdir/doc /usr/share/doc/vim-$1

cat > /etc/vimrc << "EOF"
" Begin /etc/vimrc

set nocompatible

if &term == "xterm"
    set t_Co=8
    set t_Sb=^[[4%dm
    set t_Sf=^[[3%dm
endif

" Only do this part when compiled with support for autocommands
if has("autocmd")
    " In text files, always limit the width of text to 78 characters
    autocmd BufRead *.txt set tw=78

    " When editing a file, always jump to the last cursor position
    autocmd BufReadPost *
    \ if line("'\"") > 0 && line ("'\"") <= line("$") |
    \   exe "normal! g'\"" |
    \ endif
endif

syntax on
set hlsearch
set vb t_vb=
set background=dark
set ai noic nomagic ruler aw incsearch wildmenu wrap expandtab
set ts=4 sw=4 tw=78 bs=2
set encoding=utf-8
set fileencodings=utf-8-bom,ucs-bom,utf-8,cp936,gb18030,ucs,big5
set hid

" For C language programming
" set fo=tcqro
set cin completeopt=longest,menu

" parse gradle file as groovy
au BufNewFile,BufRead *.gradle setf groovy

" open filetype detect
filetype plugin indent on
au FileType c,c++ set ts=8 sw=8
au FileType xml,html set ts=2 sw=2

" automatic save and restore folders
au BufWinLeave *.* silent mkview
au BufWinEnter *.* silent loadview

" End /etc/vimrc
EOF

    rm -rf /sources/$srcdir
    unset major minor srcdir
}

function finally_step() {
    echo -e "--------------------------------------------------------------------"
    echo -e "\nYou made it! Now there are just a few things left to take care of..."
    printf 'Total script time: %s\n' $(timer $total_time)
    echo -e "\nYou have not set a root password yet. Go ahead, I'll wait here.\n"
    passwd root
    
    echo -e "\nNow about the firmware..."
    echo "You probably want to copy the supplied Broadcom libraries to /opt/vc?"
    select yn in "Yes" "No"; do
        case $yn in
            Yes ) cd /sources &&
                  tar -xf firmware-master.tar.gz &&
                  cp -rv /sources/firmware-master/hardfp/opt/vc /opt &&
                  echo "/opt/vc/lib" >> /etc/ld.so.conf.d/broadcom.conf &&
                  ldconfig; break;;
            No ) break;;
        esac
    done
    
    echo -e "\nIf you're not going to compile your own kernel you probably want"
    echo "to copy the kernel modules from the firmware package to /lib/modules?"
    select yn in "Yes" "No"; do
        case $yn in
            Yes ) cp -rv /sources/firmware-master/modules /lib; break;;
            No ) break;;
        esac
    done

    # make SD Card Image Suitable For Distribution
    # $ parted /dev/sdb
    # $ (parted) mkpart primary fat32 1 50
    # $ (parted) mkpart primary ext4 50.3 950
    # 
    # $ mkdosfs -F 32 -n Pi-Boot -v /dev/sdb1
    # $ mkfs.ext4 -m 1 -L Pi-LFS /dev/sdb2
    # 
    # $ mount /dev/sdb1 /mnt && tar -xf Pi-Boot.tar.xz -C /mnt && umount /mnt
    # $ mount /dev/sdb2 /mnt && tar -xf Pi-LFS.tar.xz  -C /mnt && umount /mnt
    # 
    # $ dd if=/dev/sdb of=pilfs.img bs=1M count=950
    
    echo -e "\nThere, all done! Now continue reading from"
    echo -e "\"6.71. About Debugging Symbols\" to make your system bootable."
    echo "And don't forget to check out http://www.intestinate.com/pilfs/beyond.html"
    echo "when you're done with your build!"
}

#---------------------------------------------------------------
prebuild_sanity_check
check_tarballs
make_sure
build_linux_api_headers "4.4.y"     "# 6.7.  Raspberry Pi Linux API Headers"
build_manpages          "4.04"      "# 6.8.  Man-pages"
build_glibc             "2.23"      "# 6.9.  Glibc"
build_zlib              "1.2.8"     "# 6.11. Zlib"
build_file              "5.25"      "# 6.12. File"
build_binutils          "2.26"      "# 6.13. Binutils"
build_gmp               "6.1.0"     "# 6.14. GMP"
build_mpfr              "3.1.3"     "# 6.15. MPFR"
build_mpc               "1.0.3"     "# 6.16. MPC"
build_gcc               "5.3.0"     "# 6.17. GCC"
build_bzip2             "1.0.6"     "# 6.18. Bzip2"
build_pkgconfig         "0.29"      "# 6.19. Pkg-config"
build_ncurses           "6.0"       "# 6.20. Ncurses"
build_attr              "2.4.47"    "# 6.21. Attr"
build_acl               "2.2.52"    "# 6.22. Acl"
build_libcap            "2.25"      "# 6.23. Libcap"
build_sed               "4.2.2"     "# 6.24. Sed"
build_shadow            "4.2.1"     "# 6.25. Shadow"
build_psmisc            "22.21"     "# 6.26. Psmisc"
build_procpsng          "3.3.11"    "# 6.27. Procps-ng"
build_e2fsprogs         "1.42.13"   "# 6.28. E2fsprogs"
build_ianaetc           "2.30"      "# 6.29. Iana-Etc"
build_m4                "1.4.17"    "# 6.30. M4"
build_bison             "3.0.4"     "# 6.31. Bison"
build_flex              "2.6.0"     "# 6.32. Flex"
build_grep              "2.23"      "# 6.33. Grep"
build_readline          "6.3"       "# 6.34. Readline"
build_bash              "4.3.30"    "# 6.35. Bash"
build_bc                "1.06.95"   "# 6.36. Bc"
build_libtool           "2.4.6"     "# 6.37. Libtool"
build_gdbm              "1.11"      "# 6.38. GDBM"
build_expat             "2.1.0"     "# 6.39. Expat"
build_inetutils         "1.9.4"     "# 6.40. Inetutils"
build_perl              "5.22.1"    "# 6.41. Perl"
build_xmlparser         "2.44"      "# 6.42. XML::Parser"
build_autoconf          "2.69"      "# 6.43. Autoconf"
build_automake          "1.15"      "# 6.44. Automake"
build_coreutils         "8.25"      "# 6.45. Coreutils"
build_diffutils         "3.3"       "# 6.46. Diffutils"
build_gawk              "4.1.3"     "# 6.47. Gawk"
build_findutils         "4.6.0"     "# 6.48. Findutils"
build_gettext           "0.19.7"    "# 6.49. Gettext"
build_intltool          "0.51.0"    "# 6.50. Intltool"
build_gperf             "3.0.4"     "# 6.51. Gperf"
build_groff             "1.22.3"    "# 6.52. Groff"
build_xz                "5.2.2"     "# 6.53. Xz"
build_grub              "2.02"      "# 6.54. GRUB beta2"
build_less              "481"       "# 6.55. Less"
build_gzip              "1.6"       "# 6.56. Gzip"
build_iproute2          "4.4.0"     "# 6.57. IPRoute2"
build_kbd               "2.0.3"     "# 6.58. Kbd"
build_kmod              "22"        "# 6.59. Kmod"
build_libpipeline       "1.4.1"     "# 6.60. Libpipeline"
build_make              "4.1"       "# 6.61. Make"
build_patch             "2.7.5"     "# 6.62. Patch"
build_sysklogd          "1.5.1"     "# 6.63. Sysklogd"
build_sysvinit          "2.88dsf"   "# 6.64. Sysvinit"
build_tar               "1.28"      "# 6.65. Tar"
build_texinfo           "6.1"       "# 6.66. Texinfo"
build_eudev             "3.1.5"     "# 6.67. Eudev"
build_utillinux         "2.27.1"    "# 6.68. Util-linux"
build_mandb             "2.7.5"     "# 6.69. Man-DB"
build_vim               "7.4"       "# 6.70. Vim"

finally_step
#---------------------------------------------------------------
