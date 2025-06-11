#!/bin/bash -e

#Define variables
green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'
deps="meson ninja patchelf unzip curl pip flex bison zip"
workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"
ndkver="android-ndk-r28"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
sdkver="34"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa/-/archive/main/mesa-main.zip"

clear

#There are 4 functions here, simply comment to disable.
#You can insert your own function and make a pull request.
run_all(){
	check_deps
	prepare_workdir
	build_lib_for_android
	port_lib_for_magisk
	port_lib_for_adrenotools
}

check_deps(){
	echo "Checking system for required Dependencies ..."
		for deps_chk in $deps;
			do
				sleep 0.25
				if command -v "$deps_chk" >/dev/null 2>&1 ; then
					echo -e "$green - $deps_chk found $nocolor"
				else
					echo -e "$red - $deps_chk not found, can't countinue. $nocolor"
					deps_missing=1
				fi;
			done

		if [ "$deps_missing" == "1" ]
			then echo "Please install missing dependencies" && exit 1
		fi

	echo "Installing python Mako dependency (if missing) ..." $'\n'
		pip install mako &> /dev/null
}

prepare_workdir(){
	echo "Preparing work directory ..." $'\n'
		mkdir -p "$workdir" && cd "$_"

	echo "Downloading android-ndk from google server ..." $'\n'
		curl https://dl.google.com/android/repository/"$ndkver"-linux.zip --output "$ndkver"-linux.zip &> /dev/null
	echo "Exracting android-ndk ..." $'\n'
		unzip "$ndkver"-linux.zip &> /dev/null

	echo "Downloading mesa source ..." $'\n'
		curl "$mesasrc" --output mesa-main.zip &> /dev/null
	echo "Exracting mesa source ..." $'\n'
		unzip mesa-main.zip &> /dev/null
		cd mesa-main
}


build_lib_for_android(){
	#Workaround for using Clang as c compiler instead of GCC
	mkdir -p "$workdir/bin"
	ln -sf "$ndk/clang" "$workdir/bin/cc"
	ln -sf "$ndk/clang++" "$workdir/bin/c++"
	export PATH="$workdir/bin:$ndk:$PATH"
	export CC=clang
	export CXX=clang++
	export AR=llvm-ar
	export RANLIB=llvm-ranlib
	export STRIP=llvm-strip
	export OBJDUMP=llvm-objdump
	export OBJCOPY=llvm-objcopy
	export LDFLAGS="-fuse-ld=lld"

	echo "Generating build files ..." $'\n'
		cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang', '-O2']
cpp = ['ccache', '$ndk/aarch64-linux-android$sdkver-clang++', '-O2', '--start-no-unused-arguments', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++', '--end-no-unused-arguments', '-Wno-error=c++11-narrowing']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/aarch64-linux-android-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

		cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

		meson setup build-android-aarch64 \
			--cross-file "android-aarch64.txt" \
			--native-file "native.txt" \
			-Dbuildtype=release \
			-Dplatforms=android \
			-Dplatform-sdk-version="$sdkver" \
			-Dandroid-stub=true \
			-Dgallium-drivers= \
			-Dvulkan-drivers=freedreno \
			-Dvulkan-beta=true \
			-Dfreedreno-kmds=kgsl \
			-Db_lto=true \
			-Dstrip=true \
			-Degl=disabled &> "$workdir/meson_log"

	echo "Compiling build files ..." $'\n'
		ninja -C build-android-aarch64 &> "$workdir/ninja_log"

	if ! [ -a "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so ]; then
		echo -e "$red Build failed! $nocolor" && exit 1
	fi
}

port_lib_for_magisk(){
	echo "Using patchelf to match soname ..." $'\n'
		cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"
		cd "$workdir"
		patchelf --set-soname vulkan.adreno.so libvulkan_freedreno.so
		mv libvulkan_freedreno.so vulkan.adreno.so

	echo "Prepare magisk module structure ..." $'\n'
		p1="system/vendor/lib64/hw"
		mkdir -p "$magiskdir" && cd "$_"
		mkdir -p "$p1"

		meta="META-INF/com/google/android"
		mkdir -p "$meta"

		cat <<EOF >"$meta/update-binary"
#################
# Initialization
#################
umask 022
ui_print() { echo "\$1"; }
OUTFD=\$2
ZIPFILE=\$3
. /data/adb/magisk/util_functions.sh
install_module
exit 0
EOF

		cat <<EOF >"$meta/updater-script"
#MAGISK
EOF

		cat <<EOF >"module.prop"
id=turnip
name=turnip
version=$(cat $workdir/mesa-main/VERSION)
versionCode=1
author=DenomSly 
description=Turnip is an open-source vulkan driver for devices with adreno GPUs.
EOF

		cat <<EOF >"customize.sh"
MODVER=\`grep_prop version \$MODPATH/module.prop\`
MODVERCODE=\`grep_prop versionCode \$MODPATH/module.prop\`

ui_print ""
ui_print "Version=\$MODVER "
ui_print "MagiskVersion=\$MAGISK_VER"
ui_print ""
ui_print "Freedreno turnip vulkan drivers "
ui_print ""
sleep 1.25

ui_print ""
ui_print "Checking Device info ..."
sleep 1.25

[ \$(getprop ro.system.build.version.sdk) -lt 33 ] && echo "Android 13 is required! Aborting ..." && abort
echo ""
echo "Everything looks fine .... proceeding"
ui_print ""
ui_print "Installing Driver Please Wait ..."
ui_print ""

sleep 1.25
set_perm_recursive \$MODPATH/system 0 0 755 u:object_r:system_file:s0
set_perm_recursive \$MODPATH/system/vendor 0 2000 755 u:object_r:vendor_file:s0
set_perm \$MODPATH/system/vendor/lib64/hw/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0

ui_print ""
ui_print " Cleaning GPU Cache ... Please wait!"
find /data/user_de/*/*/*cache/* -iname "*shader*" -exec rm -rf {} +
find /data/data/* -iname "*shader*" -exec rm -rf {} +
find /data/data/* -iname "*graphitecache*" -exec rm -rf {} +
find /data/data/* -iname "*gpucache*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*shader*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*graphitecache*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*gpucache*" -exec rm -rf {} +

ui_print ""
ui_print "- Gpu Cache Cleared ..."
ui_print ""

ui_print "Driver installed Successfully"
sleep 1.25

ui_print ""
ui_print "All done, Please REBOOT device"
ui_print ""
ui_print "BY: @denomsly_afk"
ui_print ""
EOF

cat <<EOF >"skip_mount"
EOF

cat <<EOF >"post-fs-data.sh"
#!/bin/sh
# global_mount.sh
# mountify standalone script
# you can put or execute this on post-fs-data.sh or service.sh of a module.
# testing for overlayfs and tmpfs_xattr is on test-sysreq.sh
# No warranty.
# No rights reserved.
# This is free software; you can redistribute it and/or modify it under the terms of The Unlicense.
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH
MODDIR="${0%/*}"

# you can mimic vendor mounts like, my_bigball, vendor_dklm, mi_ext
# whatever. use what you want. provided here is just an example
FAKE_MOUNT_NAME="my_adreno"

# you can also use random characters whatever, but this might be a bad meme
# as we are trying to mimic a vendor mount, but its here if you want
# uncomment to use
# FAKE_MOUNT_NAME="$(cat /dev/urandom | tr -dc A-Za-z0-9 | head -c 10)"

# susfs usage is not required but we can use it if its there.
SUSFS_BIN=/data/adb/ksu/bin/ksu_susfs
# set to 1 to enable
mountify_use_susfs=0

# separate shit with lines
IFS="
"

# targets for specially handled mounts
targets="odm
product
system_ext
vendor"

# functions

# controlled depth ($targets fuckery)
controlled_depth() {
	if [ -z "$1" ] || [ -z "$2" ]; then return ; fi
	for DIR in $(ls -d $1/*/ | sed 's/.$//' ); do
		busybox mount -t overlay -o "lowerdir=$(pwd)/$DIR:$2$DIR" overlay "$2$DIR"
		[ $mountify_use_susfs = 1 ] && ${SUSFS_BIN} add_sus_mount "$2$DIR"
	done
}

# handle single depth (/system/bin, /system/etc, et. al)
single_depth() {
	for DIR in $( ls -d */ | sed 's/.$//' | grep -vE "(odm|product|system_ext|vendor)$" 2>/dev/null ); do
		busybox mount -t overlay -o "lowerdir=$(pwd)/$DIR:/system/$DIR" overlay "/system/$DIR"
		[ $mountify_use_susfs = 1 ] && ${SUSFS_BIN} add_sus_mount "/system/$DIR"
	done
}

# getfattr compat
if /system/bin/getfattr -d /system/bin > /dev/null 2>&1; then
	getfattr() { /system/bin/getfattr "$@"; }
else
	getfattr() { /system/bin/toybox getfattr "$@"; }
fi

# routine start

# make sure $MODDIR/skip_mount exists!
# this way manager won't mount it
# as we handle the mounting ourselves
[ ! -f $MODDIR/skip_mount ] && touch $MODDIR/skip_mount
# mountify 131 added this
# this way mountify wont remount this module
[ ! -f $MODDIR/skip_mountify ] && touch $MODDIR/skip_mountify

# this is a fast lookup for a writable dir
# these tends to be always available
[ -w /mnt ] && MNT_FOLDER=/mnt
[ -w /mnt/vendor ] && MNT_FOLDER=/mnt/vendor

# make sure fake_mount name does not exist
if [ -d "$MNT_FOLDER/$FAKE_MOUNT_NAME" ]; then 
	exit 1
fi


BASE_DIR="$MODDIR/system"

# copy it
cd "$MNT_FOLDER" && cp -Lrf "$BASE_DIR" "$FAKE_MOUNT_NAME"

# then we make sure its there
if [ ! -d "$MNT_FOLDER/$FAKE_MOUNT_NAME" ]; then
	echo "standalone lol exit"
	exit 1
fi

# go inside
cd "$MNT_FOLDER/$FAKE_MOUNT_NAME"

# here we mirror selinux context, if we dont, we get "u:object_r:tmpfs:s0"
for file in $( find -L $BASE_DIR | sed "s|$BASE_DIR||g" ) ; do 
	# echo "mountify_debug chcorn $BASE_DIR$file to $MNT_FOLDER/$FAKE_MOUNT_NAME$file" >> /dev/kmsg
	busybox chcon --reference="$BASE_DIR$file" "$MNT_FOLDER/$FAKE_MOUNT_NAME$file"
done

# catch opaque dirs, requires getfattr
for dir in $( find -L $BASE_DIR -type d ) ; do
	if getfattr -d "$dir" | grep -q "trusted.overlay.opaque" ; then
		# echo "mountify_debug: opaque dir $dir found!" >> /dev/kmsg
		opaque_dir=$(echo "$dir" | sed "s|$BASE_DIR|.|")
		busybox setfattr -n trusted.overlay.opaque -v y "$opaque_dir"
		# echo "mountify_debug: replaced $opaque_dir!" >> /dev/kmsg
	fi
done

# now here we mount
# handle single depth
single_depth
# handle this stance when /product is a symlink to /system/product
for folder in $targets ; do 
	# reset cwd due to loop
	cd "$MNT_FOLDER/$FAKE_MOUNT_NAME"
	if [ -L "/$folder" ] && [ ! -L "/system/$folder" ]; then
		# legacy, so we mount at /system
		controlled_depth "$folder" "/system/"
	else
		# modern, so we mount at root
		controlled_depth "$folder" "/"
	fi
done     
EOF

cat <<EOF >"uninstall.sh"
# Cache cleaner
find /data/user_de/*/*/*cache/* -iname "*shader*" -exec rm -rf {} +
find /data/data/* -iname "*shader*" -exec rm -rf {} +
find /data/data/* -iname "*graphitecache*" -exec rm -rf {} +
find /data/data/* -iname "*gpucache*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*shader*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*graphitecache*" -exec rm -rf {} +
find /data_mirror/data*/*/*/*/* -iname "*gpucache*" -exec rm -rf {} +
EOF
     
	echo "Copy necessary files from work directory ..." $'\n'
		cp "$workdir"/vulkan.adreno.so "$magiskdir"/"$p1"

	echo "Packing files in to magisk module ..." $'\n'
		zip -r "$workdir"/turnip.zip ./* &> /dev/null
		if ! [ -a "$workdir"/turnip.zip ];
			then echo -e "$red-Packing failed!$nocolor" && exit 1
			else echo -e "$green-All done, the module saved to;$nocolor" && echo "$workdir"/turnip.zip
		fi
}

port_lib_for_adrenotools(){
	libname=vulkan.freedreno.so
	echo "Using patchelf to match soname" $'\n'
		cp "$workdir"/mesa-main/build-android-aarch64/src/freedreno/vulkan/libvulkan_freedreno.so "$workdir"/$libname
		cd "$workdir"
		patchelf --set-soname $libname $libname
	echo "Preparing meta.json" $'\n'
		cat <<EOF > "meta.json"
{
	"schemaVersion": 1,
	"name": "freedreno_turnip-CI",
	"description": "$(date)",
	"author": "DenomSly",
	"packageVersion": "1",
	"vendor": "Mesa",
	"driverVersion": "$(cat $workdir/mesa-main/VERSION)",
	"minApi": $sdkver,
	"libraryName": "$libname"
}
EOF

	zip -9 "$workdir"/turnip_adrenotools.zip $libname meta.json &> /dev/null
	if ! [ -a "$workdir"/turnip_adrenotools.zip ];
		then echo -e "$red-Packing turnip_adrenotools.zip failed!$nocolor" && exit 1
		else echo -e "$green-All done, the module saved to;$nocolor" && echo "$workdir"/turnip_adrenotools.zip
	fi
}

run_all
