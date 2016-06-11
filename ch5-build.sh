#!/bin/bash
#
# PiLFS Build Script LFS-7.9 v1.0, modify by Fangxm
# Builds chapters 5.4 - Binutils to 5.34 - Xz
# http://www.intestinate.com/pilfs
#
# Optional parameteres below:

PARALLEL_JOBS=4                 # Number of parallel make jobs, 1 for RPi1 and 4 for RPi2 and RPi3 recommended.
STRIP_AND_DELETE_DOCS=1         # Strip binaries and delete manpages to save space at the end of chapter 5?

# End of optional parameters

set -o nounset
set -o errexit

function prepare_env {
    groupadd lfs
    useradd -s /bin/bash -g lfs -m -k /dev/null lfs

cat >> /etc/profile << "EOF"
export LFS=/mnt/lfs
export LFS_TGT=$(uname -m)-lfs-linux-gnueabihf
EOF
    source /etc/profile

    mount -v -t ext4 /dev/mmcblk0p3 $LFS
    mkdir -pv $LFS/{sources,tools}
    ln -sv $LFS/tools /
    chown -R lfs:lfs $LFS/sources $LFS/tools

    su - lfs

cat > ~/.bash_profile << "EOF"
export PATH=/tools/bin:/bin:/usr/bin
EOF
    source ~/.bash_profile
}

function prebuild_sanity_check {
    if [[ $(whoami) != "lfs" ]] ; then
        echo "Not running as user lfs, you should be!"
        exit 1
    fi

    if ! [[ -v LFS ]] ; then
        echo "You forgot to set your LFS environment variable!"
        exit 1
    fi

    if ! [[ -v LFS_TGT ]] || [[ $LFS_TGT != "armv6l-lfs-linux-gnueabihf" &&
        $LFS_TGT != "armv7l-lfs-linux-gnueabihf" ]] ; then
        echo "Your LFS_TGT variable should be set to armv6l-lfs-linux-gnueabihf"
        echo "for RPi1 or armv7l-lfs-linux-gnueabihf for RPi2 and RPi3"
        exit 1
    fi

    if ! [[ -d $LFS ]] ; then
        echo "Your LFS directory doesn't exist!"
        exit 1
    fi

    if ! [[ -d $LFS/sources ]] ; then
        echo "Can't find your sources directory!"
        exit 1
    fi

    if [[ $(stat -c %U $LFS/sources) != "lfs" ]] ; then
        echo "The sources directory should be owned by user lfs!"
        exit 1
    fi

    if ! [[ -d $LFS/tools ]] ; then
        echo "Can't find your tools directory!"
        exit 1
    fi

    if [[ $(stat -c %U $LFS/tools) != "lfs" ]] ; then
        echo "The tools directory should be owned by user lfs!"
        exit 1
    fi
}

function check_tarballs {
    cat sources-list | grep -Ev '^#|^$' | while read tarball ; do
        if ! [[ -f $LFS/sources/$tarball ]] ; then
            echo "Can't find $LFS/sources/$tarball!"
            exit 1
        fi
    done
}

function do_strip {
    set +o errexit
    if [[ $STRIP_AND_DELETE_DOCS = 1 ]] ; then
        strip --strip-debug /tools/lib/*
        /usr/bin/strip --strip-unneeded /tools/{,s}bin/*
        rm -rf /tools/{,share}/{info,man,doc}
    fi
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

function check_swap {
    if [[ $(free | grep 'Swap:' | tr -d ' ' | cut -d ':' -f2) == "000" ]] ; then
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
}

function make_sure {
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
sbu_time=$(timer)

function build_binutils_pass1() {
    cd $LFS/sources && echo $2-$1
    tar -xf binutils-$1.tar.bz2 && cd binutils-$1
    mkdir build && cd build

    ../configure --prefix=/tools   \
        --with-sysroot=$LFS        \
        --with-lib-path=/tools/lib \
        --target=$LFS_TGT          \
        --disable-nls              \
        --disable-werror
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/binutils-$1
    
    echo -e "\n=========================="
    printf 'Your SBU time is: %s\n' $(timer $sbu_time)
    echo -e "==========================\n"
}

function build_gcc_pass1() {
    cd $LFS/sources && echo $2-$1
    tar -xf gcc-$1.tar.bz2 && cd gcc-$1

    case $(uname -m) in
      armv6l) patch -Np1 -i ../gcc-$1-rpi1-cpu-default.patch ;;
      armv7l) case $(sed -n '/^Revision/s/^.*: \(.*\)/\1/p' < /proc/cpuinfo) in
        a02082|a22082) patch -Np1 -i ../gcc-$1-rpi3-cpu-default.patch ;;
        *) patch -Np1 -i ../gcc-$1-rpi2-cpu-default.patch ;;
        esac
      ;;
    esac

    tar -xf ../mpfr-3.1.3.tar.xz && mv mpfr-3.1.3 mpfr
    tar -xf ../gmp-6.1.0.tar.xz  && mv gmp-6.1.0 gmp
    tar -xf ../mpc-1.0.3.tar.gz  && mv mpc-1.0.3 mpc

    for file in $(find gcc/config -name linux64.h \
        -o -name linux.h \
        -o -name sysv4.h \
        -o -name linux-eabi.h \
        -o -name linux-elf.h)
    do
      cp -uv $file{,.orig}
      sed -e 's@/lib\(64\)\?\(32\)\?/ld@/tools&@g' \
          -e 's@/usr@/tools@g' $file.orig > $file
      echo '
    #undef STANDARD_STARTFILE_PREFIX_1
    #undef STANDARD_STARTFILE_PREFIX_2
    #define STANDARD_STARTFILE_PREFIX_1 "/tools/lib/"
    #define STANDARD_STARTFILE_PREFIX_2 ""' >> $file
      touch $file.orig
    done
    mkdir -v build
    cd build
    ../configure                                       \
        --target=$LFS_TGT                              \
        --prefix=/tools                                \
        --with-glibc-version=2.11                      \
        --with-sysroot=$LFS                            \
        --with-newlib                                  \
        --without-headers                              \
        --with-local-prefix=/tools                     \
        --with-native-system-header-dir=/tools/include \
        --disable-nls                                  \
        --disable-shared                               \
        --disable-multilib                             \
        --disable-decimal-float                        \
        --disable-threads                              \
        --disable-libatomic                            \
        --disable-libgomp                              \
        --disable-libmpx                               \
        --disable-libquadmath                          \
        --disable-libssp                               \
        --disable-libvtv                               \
        --disable-libstdcxx                            \
        --enable-languages=c,c++

    # Workaround for a problem introduced with GMP 5.1.0.
    # If configured by gcc with the "none" host & target,
    # it will result in undefined references to
    # '__gmpn_invert_limb' during linking.
    sed -i 's/none-/armv6l-/' Makefile

    make
    make install

    rm -rf $LFS/sources/gcc-$1
}

function build_linux_api_headers() {
    cd $LFS/sources && echo $2-$1
    tar -xf rpi-$1.tar.gz && cd linux-rpi-$1

    make mrproper
    make INSTALL_HDR_PATH=dest headers_install
    cp -rv dest/include/* /tools/include
}

function build_glibc() {
    cd $LFS/sources && echo $2-$1
    tar -xf glibc-$1.tar.xz && cd glibc-$1
    mkdir build && cd build

    ../configure                           \
        --prefix=/tools                    \
        --host=$LFS_TGT                    \
        --build=$(../scripts/config.guess) \
        --disable-profile                  \
        --enable-kernel=2.6.32             \
        --enable-obsolete-rpc              \
        --with-headers=/tools/include      \
        libc_cv_forced_unwind=yes          \
        libc_cv_ctors_header=yes           \
        libc_cv_c_cleanup=yes
    make -j $PARALLEL_JOBS
    make install

    # Compatibility symlink for non ld-linux-armhf awareness
    ln -sv ld-$1.so $LFS/tools/lib/ld-linux.so.3

    rm -rf $LFS/sources/glibc-$1
}

function build_libstdcxx() {
    cd $LFS/sources && echo $2-$1
    tar -xf gcc-$1.tar.bz2 && cd gcc-$1
    mkdir build && cd build

    ../libstdc++-v3/configure       \
        --host=$LFS_TGT             \
        --prefix=/tools             \
        --disable-multilib          \
        --disable-nls               \
        --disable-libstdcxx-threads \
        --disable-libstdcxx-pch     \
        --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/$1
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/gcc-$1
}

function build_binutils_pass2() {
    cd $LFS/sources && echo $2-$1
    tar -xf binutils-$1.tar.bz2 && cd binutils-$1
    mkdir build && cd build

    CC=$LFS_TGT-gcc                \
    AR=$LFS_TGT-ar                 \
    RANLIB=$LFS_TGT-ranlib         \
    ../configure                   \
        --prefix=/tools            \
        --disable-nls              \
        --disable-werror           \
        --with-lib-path=/tools/lib \
        --with-sysroot
    make -j $PARALLEL_JOBS
    make install
    make -C ld clean
    make -C ld LIB_PATH=/usr/lib:/lib
    cp -v ld/ld-new /tools/bin

    rm -rf $LFS/sources/binutils-$1
}

function build_gcc_pass2() {
    cd $LFS/sources && echo $2-$1
    tar -xf gcc-$1.tar.bz2 && cd gcc-$1

    case $(uname -m) in
      armv6l) patch -Np1 -i ../gcc-$1-rpi1-cpu-default.patch ;;
      armv7l) case $(sed -n '/^Revision/s/^.*: \(.*\)/\1/p' < /proc/cpuinfo) in
        a02082|a22082) patch -Np1 -i ../gcc-$1-rpi3-cpu-default.patch ;;
        *) patch -Np1 -i ../gcc-$1-rpi2-cpu-default.patch ;;
        esac
      ;;
    esac

    cat gcc/limitx.h gcc/glimits.h gcc/limity.h > \
      `dirname $($LFS_TGT-gcc -print-libgcc-file-name)`/include-fixed/limits.h

    for file in $(find gcc/config -name linux64.h \
        -o -name linux.h \
        -o -name sysv4.h \
        -o -name linux-eabi.h \
        -o -name linux-elf.h)
    do
      cp -uv $file{,.orig}
      sed -e 's@/lib\(64\)\?\(32\)\?/ld@/tools&@g' \
          -e 's@/usr@/tools@g' $file.orig > $file
      echo '
    #undef STANDARD_STARTFILE_PREFIX_1
    #undef STANDARD_STARTFILE_PREFIX_2
    #define STANDARD_STARTFILE_PREFIX_1 "/tools/lib/"
    #define STANDARD_STARTFILE_PREFIX_2 ""' >> $file
      touch $file.orig
    done

    tar -xf ../mpfr-3.1.3.tar.xz && mv mpfr-3.1.3 mpfr
    tar -xf ../gmp-6.1.0.tar.xz  && mv gmp-6.1.0 gmp
    tar -xf ../mpc-1.0.3.tar.gz  && mv mpc-1.0.3 mpc
    mkdir build && cd build

    CC=$LFS_TGT-gcc                                    \
    CXX=$LFS_TGT-g++                                   \
    AR=$LFS_TGT-ar                                     \
    RANLIB=$LFS_TGT-ranlib                             \
    ../configure                                       \
        --prefix=/tools                                \
        --with-local-prefix=/tools                     \
        --with-native-system-header-dir=/tools/include \
        --enable-languages=c,c++                       \
        --disable-libstdcxx-pch                        \
        --disable-multilib                             \
        --disable-bootstrap                            \
        --disable-libgomp

    # Workaround for a problem introduced with GMP 5.1.0.
    # If configured by gcc with the "none" host & target,
    # it will result in undefined references to
    # '__gmpn_invert_limb' during linking.
    sed -i 's/none-/armv6l-/' Makefile

    make
    make install
    ln -sv gcc /tools/bin/cc

    rm -rf $LFS/sources/gcc-$1
}

function build_tclcore() {
    cd $LFS/sources && echo $2-$1
    tar -xf tcl-core$1-src.tar.gz && cd tcl$1

    cd unix
    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install
    chmod -v u+w /tools/lib/libtcl8.6.so
    make install-private-headers
    ln -sv tclsh8.6 /tools/bin/tclsh

    rm -rf $LFS/sources/tcl$1
}

function build_expect() {
    cd $LFS/sources && echo $2-$1
    tar -xf expect$1.tar.gz && cd expect$1

    cp -v configure{,.orig}
    sed 's:/usr/local/bin:/bin:' configure.orig > configure

    ./configure --prefix=/tools \
        --with-tcl=/tools/lib   \
        --with-tclinclude=/tools/include
    make -j $PARALLEL_JOBS
    make SCRIPTS="" install

    rm -rf $LFS/sources/expect$1
}

function build_dejagnu() {
    cd $LFS/sources && echo $2-$1
    tar -xf dejagnu-$1.tar.gz && cd dejagnu-$1

    ./configure --prefix=/tools
    make install

    rm -rf $LFS/sources/dejagnu-$1
}

function build_check() {
    cd $LFS/sources && echo $2-$1
    tar -xf check-$1.tar.gz && cd check-$1

    PKG_CONFIG= ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/check-$1
}

function build_ncurses() {
    cd $LFS/sources && echo $2-$1
    tar -xf ncurses-$1.tar.gz && cd ncurses-$1

    sed -i s/mawk// configure
    ./configure --prefix=/tools \
        --with-shared   \
        --without-debug \
        --without-ada   \
        --enable-widec  \
        --enable-overwrite
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/ncurses-$1
}

function build_bash() {
    cd $LFS/sources && echo $2-$1
    tar -zxf bash-$1.tar.gz
    cd bash-$1

    ./configure --prefix=/tools --without-bash-malloc
    make -j $PARALLEL_JOBS
    make install
    ln -sv bash /tools/bin/sh

    rm -rf $LFS/sources/bash-$1
}

function build_bzip2() {
    cd $LFS/sources && echo $2-$1
    tar -xf bzip2-$1.tar.gz && cd bzip2-$1

    make -j $PARALLEL_JOBS
    make PREFIX=/tools install

    rm -rf $LFS/sources/bzip2-$1
}

function build_coreutils() {
    cd $LFS/sources && echo $2-$1
    tar -xf coreutils-$1.tar.xz && cd coreutils-$1

    ./configure --prefix=/tools --enable-install-program=hostname
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/coreutils-$1
}
    
function build_diffutils() {
    cd $LFS/sources && echo $2-$1
    tar -Jxf diffutils-$1.tar.xz && cd diffutils-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/diffutils-$1
}
    
function build_file() {
    cd $LFS/sources && echo $2-$1
    tar -xf file-$1.tar.gz && cd file-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/file-$1
}
    
function build_findutils() {
    cd $LFS/sources && echo $2-$1
    tar -xf findutils-$1.tar.gz && cd findutils-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/findutils-$1
}
    
function build_gawk() {
    cd $LFS/sources && echo $2-$1
    tar -xf gawk-$1.tar.xz && cd gawk-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/gawk-$1
}
    
function build_gettext() {
    cd $LFS/sources && echo $2-$1
    tar -xf gettext-$1.tar.xz && cd gettext-$1

    cd gettext-tools
    EMACS="no" ./configure --prefix=/tools --disable-shared
    make -C gnulib-lib
    make -C intl pluralx.c
    make -C src msgfmt
    make -C src msgmerge
    make -C src xgettext
    cp -v src/{msgfmt,msgmerge,xgettext} /tools/bin

    rm -rf $LFS/sources/gettext-$1
}
    
function build_grep() {
    cd $LFS/sources && echo $2-$1
    tar -xf grep-$1.tar.xz && cd grep-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/grep-$1
}
    
function build_gzip() {
    cd $LFS/sources && echo $2-$1
    tar -xf gzip-$1.tar.xz && cd gzip-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/gzip-$1
}
    
function build_m4() {
    cd $LFS/sources && echo $2-$1
    tar -xf m4-$1.tar.xz && cd m4-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/m4-$1
}
    
function build_make() {
    cd $LFS/sources && echo $2-$1
    tar -xf make-$1.tar.bz2 && cd make-$1

    ./configure --prefix=/tools --without-guile
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/make-$1
}
    
function build_patch() {
    cd $LFS/sources && echo $2-$1
    tar -xf patch-$1.tar.xz && cd patch-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/patch-$1
}
    
function build_perl() {
    cd $LFS/sources && echo $2-$1
    tar -xf perl-$1.tar.bz2 && cd perl-$1

    sh Configure -des -Dprefix=/tools -Dlibs=-lm
    make -j $PARALLEL_JOBS
    cp -v perl cpan/podlators/pod2man /tools/bin
    mkdir -pv /tools/lib/perl5/$1
    cp -Rv lib/* /tools/lib/perl5/$1

    rm -rf $LFS/sources/perl-$1
}
    
function build_sed() {
    cd $LFS/sources && echo $2-$1
    tar -xf sed-$1.tar.bz2 && cd sed-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/sed-$1
}
    
function build_tar() {
    cd $LFS/sources && echo $2-$1
    tar -xf tar-$1.tar.xz && cd tar-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/tar-$1
}
    
function build_texinfo() {
    cd $LFS/sources && echo $2-$1
    tar -xf texinfo-$1.tar.xz && cd texinfo-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/texinfo-$1
}
    
function build_utillinux() {
    cd $LFS/sources && echo $2-$1
    tar -xf util-linux-$1.tar.xz && cd util-linux-$1

    ./configure --prefix=/tools        \
        --without-python               \
        --disable-makeinstall-chown    \
        --without-systemdsystemunitdir \
        PKG_CONFIG=""
    make
    make install

    rm -rf $LFS/sources/util-linux-$1
}
    
function build_xz() {
    cd $LFS/sources && echo $2-$1
    tar -xf xz-$1.tar.xz && cd xz-$1

    ./configure --prefix=/tools
    make -j $PARALLEL_JOBS
    make install

    rm -rf $LFS/sources/xz-$1
}

#---------------------------------------------------------------
prebuild_sanity_check
check_tarballs
check_swap
make_sure

build_binutils_pass1    "2.26"      "# 5.4.  Binutils Pass 1"
build_gcc_pass1         "5.3.0"     "# 5.5.  gcc Pass 1"
build_linux_api_headers "4.4.y"     "# 5.6.  Raspberry Pi Linux API Headers"
build_glibc             "2.23"      "# 5.7.  Glibc"
build_libstdcxx         "5.3.0"     "# 5.8.  Libstdc++"
build_binutils_pass2    "2.26"      "# 5.9.  Binutils Pass 2"
build_gcc_pass2         "5.3.0"     "# 5.10. gcc Pass 2"
build_tclcore           "8.6.4"     "# 5.11. Tcl-core"
build_expect            "5.45"      "# 5.12. Expect"
build_dejagnu           "1.5.3"     "# 5.13. DejaGNU"
build_check             "0.10.0"    "# 5.14. Check"
build_ncurses           "6.0"       "# 5.15. Ncurses"
build_bash              "4.3.30"    "# 5.16. Bash"
build_bzip2             "1.0.6"     "# 5.17. Bzip2"
build_coreutils         "8.25"      "# 5.18. Coreutils"
build_diffutils         "3.3"       "# 5.19. Diffutils"
build_file              "5.25"      "# 5.20. File"
build_findutils         "4.6.0"     "# 5.21. Findutils"
build_gawk              "4.1.3"     "# 5.22. Gawk"
build_gettext           "0.19.7"    "# 5.23. Gettext"
build_grep              "2.23"      "# 5.24. Grep"
build_gzip              "1.6"       "# 5.25. Gzip"
build_m4                "1.4.17"    "# 5.26. M4"
build_make              "4.1"       "# 5.27. Make"
build_patch             "2.7.5"     "# 5.28. Patch"
build_perl              "5.22.1"    "# 5.29. Perl"
build_sed               "4.2.2"     "# 5.30. Sed"
build_tar               "1.28"      "# 5.31. Tar"
build_texinfo           "6.1"       "# 5.32. Texinfo"
build_utillinux         "2.27.1"    "# 5.33. Util-linux"
build_xz                "5.2.2"     "# 5.34. Xz"

do_strip

echo -e "----------------------------------------------------"
echo -e "\nYou made it! This is the end of chapter 5!"
printf 'Total script time: %s\n' $(timer $total_time)
echo -e "Now continue reading from \"5.36. Changing Ownership\""
#---------------------------------------------------------------
