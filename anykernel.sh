### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=AOSPA GKI
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=marble
device.name2=marblein
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install

## boot shell variables
block=boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

split_boot # skip ramdisk unpack

########## FLASH BOOT & VENDOR_DLKM START ##########


extract_erofs() {
	local img_file=$1
	local out_dir=$2

	${bin}/extract.erofs -i "$img_file" -x -T8 -o "$out_dir" &> /dev/null
}

mkfs_erofs() {
	local work_dir=$1
	local out_file=$2
	local partition_name

	partition_name=$(basename "$work_dir")

	${bin}/mkfs.erofs \
		--mount-point "/${partition_name}" \
		--fs-config-file "${work_dir}/../config/${partition_name}_fs_config" \
		--file-contexts  "${work_dir}/../config/${partition_name}_file_contexts" \
		-z lz4hc \
		"$out_file" "$work_dir"
}

is_mounted() { mount | grep -q " $1 "; }

sha1() { ${bin}/magiskboot sha1 "$1"; }

apply_patch() {
	# apply_patch <src_path> <src_sha1> <dst_sha1> <bs_patch>
	local src_path=$1
	local src_sha1=$2
	local dst_sha1=$3
	local bs_patch=$4
	local file_sha1

	file_sha1=$(sha1 $src_path)
	[ "$file_sha1" == "$dst_sha1" ] && return 0
	[ "$file_sha1" == "$src_sha1" ] && ${bin}/bspatch "$src_path" "$src_path" "$bs_patch"
	[ "$(sha1 $src_path)" == "$dst_sha1" ] || abort "! Failed to patch $src_path!"
}

get_keycheck_result() {
	# Default behavior:
	# - press Vol+: return true (0)
	# - press Vol-: return false (1)

	local rc_1 rc_2

	while true; do
		# The first execution responds to the button press event,
		# the second execution responds to the button release event.
		${bin}/keycheck; rc_1=$?
		${bin}/keycheck; rc_2=$?
		[ "$rc_1" == "$rc_2" ] || continue
		case "$rc_2" in
			"$KEYCODE_UP") return 0;;
			"$KEYCODE_DOWN") return 1;;
		esac
	done
}

get_size() {
	local _path=$1
	local _size

	if [ -d "$_path" ]; then
		du -bs $_path | awk '{print $1}'
		return
	fi
	if [ -b "$_path" ]; then
		_size=$(blockdev --getsize64 $_path) && {
			echo $_size
			return
		}
	fi
	wc -c < $_path
}

bytes_to_mb() {
	echo $1 | awk '{printf "%.1fM", $1 / 1024 / 1024}'
}

check_super_device_size() {
	# Check super device size
	local block_device_size block_device_size_lp

	block_device_size=$(get_size /dev/block/by-name/super) || \
		abort "! Failed to get super block device size (by blockdev)!"
	block_device_size_lp=$(${bin}/lpdump 2>/dev/null | grep -m1 -E 'Size: [[:digit:]]+ bytes$' | awk '{print $2}') || \
		abort "! Failed to get super block device size (by lpdump)!"
	ui_print "- Super block device size:"
	ui_print "  - Read by blockdev: $block_device_size"
	ui_print "  - Read by lpdump: $block_device_size_lp"
	[ "$block_device_size" == "9663676416" ] && [ "$block_device_size_lp" == "9663676416" ] || \
		abort "! Super block device size mismatch!"
}

# copy_gpu_pwrlevels_conf <orig dtb file> <new dtb file>
copy_gpu_pwrlevels_conf() {
	local orig_dtb=$1
	local new_dtb=$2
	local KGSL_NODE="/soc/qcom,kgsl-3d0@3d00000"
	local PWRLEVELS_NODE="${KGSL_NODE}/qcom,gpu-pwrlevels"
	local node reg gpu_freq bus_freq bus_min bus_max level cx_level acd_level initial_pwrlevel

	# Clear the gpu frequency and voltage configuration of new_dtb
	for node in $(${bin}/fdtget "$new_dtb" "$PWRLEVELS_NODE" -l); do
		${bin}/fdtput "$new_dtb" -r "/soc/qcom,kgsl-3d0@3d00000/qcom,gpu-pwrlevels/${node}"
	done

	for node in $(${bin}/fdtget "$orig_dtb" /soc/qcom,kgsl-3d0@3d00000/qcom,gpu-pwrlevels -l | sort -r); do
		# Read
		      reg=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "reg" -tu)
		 gpu_freq=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,gpu-freq" -tu)
		 bus_freq=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,bus-freq" -tu)
		  bus_min=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,bus-min" -tu)
		  bus_max=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,bus-max" -tu)
		    level=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,level" -tu)
		 cx_level=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,cx-level" -tu)
		acd_level=$(${bin}/fdtget "$orig_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,acd-level" -tx)

		# Write
		${bin}/fdtput "$new_dtb" -c "${PWRLEVELS_NODE}/${node}"
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,cx-level"  "$cx_level" -tu
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,acd-level" "$acd_level" -tx
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,bus-max"   "$bus_max" -tu
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,bus-min"   "$bus_min" -tu
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,bus-freq"  "$bus_freq" -tu
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,level"     "$level" -tu
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "qcom,gpu-freq"  "$gpu_freq" -tu
		${bin}/fdtput "$new_dtb" "${PWRLEVELS_NODE}/${node}" "reg" "$reg" -tu
	done

	initial_pwrlevel=$(${bin}/fdtget "$orig_dtb" "$KGSL_NODE" "qcom,initial-pwrlevel" -tu)
	${bin}/fdtput "$new_dtb" "$KGSL_NODE" "qcom,initial-pwrlevel" "$initial_pwrlevel" -tu
}

random_strings() {
	local len=$1

	cat /dev/urandom | tr -dc 'a-zA-Z' | head -c $len
}

# Staging unmodified partition images
mkdir -p ${home}/_orig
cp ${home}/boot.img ${home}/_orig/boot.img

# Check snapshot status
# Technical details: https://blog.xzr.moe/archives/30/
${bin}/snapshotupdater_static dump &>/dev/null
rc=$?
if [ "$rc" != 0 ]; then
	ui_print " "
	ui_print "Cannot get snapshot status via snapshotupdater_static! rc=$rc."
	if ${BOOTMODE}; then
		ui_print "If you are installing the kernel in an app, try using another app."
		ui_print "Recommend KernelFlasher:"
		ui_print "  https://github.com/capntrips/KernelFlasher/releases"
	fi
	abort "Aborting..."
fi
snapshot_status=$(${bin}/snapshotupdater_static dump 2>/dev/null | grep '^Update state:' | awk '{print $3}')
ui_print "Current snapshot state: $snapshot_status"
if [ "$snapshot_status" != "none" ]; then
	ui_print " "
	ui_print "Seems like you just installed a rom update."
	ui_print "Please use the \"Merge Snapshots\" feature in TWRP's"
	ui_print "advanced menu first to merge snapshots immediately."
	abort "Aborting..."
fi
unset rc snapshot_status

# Check vendor_dlkm partition status
[ -d /vendor_dlkm ] || mkdir /vendor_dlkm
is_mounted /vendor_dlkm || \
	mount /vendor_dlkm -o ro || mount /dev/block/mapper/vendor_dlkm${slot} /vendor_dlkm -o ro || \
		abort "! Failed to mount /vendor_dlkm"

$BOOTMODE || umount /vendor_dlkm

export magisk_patched

# Fix unable to mount image as read-write in recovery
$BOOTMODE || setenforce 0

ui_print " "
if true; then  # I don't want to adjust the indentation of the code block below, so leave it as is.
	do_check_super_device_size=false

	# Dump vendor_dlkm partition image
	dd if=/dev/block/mapper/vendor_dlkm${slot} of=${home}/vendor_dlkm.img
	cp ${home}/vendor_dlkm.img ${home}/_orig/vendor_dlkm.img
	vendor_dlkm_block_size=$(get_size /dev/block/mapper/vendor_dlkm${slot})

	# Backup kernel and vendor_dlkm image
	ui_print "- Backing up kernel, vendor_boot, vendor_dlkm"
	ui_print "  and dtbo partition..."

	backup_package=/sdcard/aospa-restore-kernel-$(file_getprop /system/build.prop ro.build.version.incremental)-$(date +"%Y%m%d-%H%M%S").zip

	${bin}/7za a -tzip -bd $backup_package \
		${home}/META-INF ${bin} ${home}/LICENSE ${home}/_restore_anykernel.sh \
		${split_img}/kernel \
		${home}/vendor_dlkm.img \
		/dev/block/bootdevice/by-name/vendor_boot${slot} \
		/dev/block/bootdevice/by-name/dtbo${slot}
	${bin}/7za rn -bd $backup_package kernel Image
	${bin}/7za rn -bd $backup_package _restore_anykernel.sh anykernel.sh
	${bin}/7za rn -bd $backup_package vendor_boot${slot} vendor_boot.img
	${bin}/7za rn -bd $backup_package dtbo${slot} dtbo.img
	sync

	ui_print " "
	ui_print "- The current kernel, vendor_boot, vendor_dlkm"
	ui_print "  and dtbo have been backedup to:"
	ui_print "  $backup_package"
	ui_print "- If you encounter an unexpected situation,"
	ui_print "  or want to restore the stock kernel,"
	ui_print "  please flash it in TWRP or some supported apps."
	ui_print " "
	touch ${home}/do_backup_flag

	if ! $BOOTMODE && [ ! -d /twres ]; then
		ui_print "============================================================"
		ui_print "! Warning: Please transfer the backup file just generated to"
		ui_print "! another device via ADB, as it will be lost after reboot!"
		ui_print "============================================================"
		ui_print " "
		sleep 3
	fi

	unset backup_package

	ui_print "- Unpacking /vendor_dlkm partition..."
	extract_vendor_dlkm_dir=${home}/_extract_vendor_dlkm_$(random_strings 3)
	mkdir -p $extract_vendor_dlkm_dir
	vendor_dlkm_is_ext4=false
	extract_erofs ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir || vendor_dlkm_is_ext4=true
	sync

	if ${vendor_dlkm_is_ext4}; then
		ui_print "- /vendor_dlkm seems to be in ext4 file system."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o ro -t ext4 || \
			abort "! Unsupported file system!"
		vendor_dlkm_full_space=$(df -B1 | grep -E -m1 "$(basename $extract_vendor_dlkm_dir)\$" | awk '{print $2}')
		vendor_dlkm_used_space=$(df -B1 | grep -E -m1 "$(basename $extract_vendor_dlkm_dir)\$" | awk '{print $3}')
		vendor_dlkm_free_space=$(df -B1 | grep -E -m1 "$(basename $extract_vendor_dlkm_dir)\$" | awk '{print $4}')
		vendor_dlkm_stock_modules_size=$(get_size ${extract_vendor_dlkm_dir}/lib/modules)
		ui_print "- /vendor_dlkm partition space:"
		ui_print "  - Total space: $(bytes_to_mb $vendor_dlkm_full_space)"
		ui_print "  - Used space: $(bytes_to_mb $vendor_dlkm_used_space)"
		ui_print "  - Free space: $(bytes_to_mb $vendor_dlkm_free_space)"
		umount $extract_vendor_dlkm_dir

		vendor_dlkm_new_modules_size=$(get_size ${home}/_vendor_dlkm_modules)
		vendor_dlkm_need_size=$((vendor_dlkm_used_space - vendor_dlkm_stock_modules_size + vendor_dlkm_new_modules_size + 10*1024*1024))
		if [ "$vendor_dlkm_need_size" -ge "$vendor_dlkm_full_space" ]; then
			# Resize vendor_dlkm image
			ui_print "- /vendor_dlkm partition does not have enough free space!"
			ui_print "- Trying to resize..."

			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img
			vendor_dlkm_resized_size=$(echo $vendor_dlkm_need_size | awk '{printf "%dM", ($1 / 1024 / 1024 + 1)}')
			${bin}/resize2fs ${home}/vendor_dlkm.img $vendor_dlkm_resized_size || \
				abort "! Failed to resize vendor_dlkm image!"
			ui_print "- Resized vendor_dlkm.img size: ${vendor_dlkm_resized_size}."
			# e2fsck again
			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img

			do_check_super_device_size=true
			unset vendor_dlkm_resized_size
		else
			ui_print "- /vendor_dlkm partition has sufficient space."
		fi

		ui_print "- Trying to mount vendor_dlkm image as read-write..."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o rw -t ext4 || \
			abort "! Failed to mount vendor_dlkm.img as read-write!"

		unset vendor_dlkm_full_space vendor_dlkm_used_space vendor_dlkm_free_space vendor_dlkm_stock_modules_size vendor_dlkm_new_modules_size vendor_dlkm_need_size
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/lib/modules
	else
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
	fi

	ui_print "- Updating /vendor_dlkm image..."
	rm -f ${extract_vendor_dlkm_modules_dir}/*
	cp ${home}/_vendor_dlkm_modules/* ${extract_vendor_dlkm_modules_dir}/ || \
		abort "! Failed to update modules! No enough free space?"
	cp ${home}/vertmp ${extract_vendor_dlkm_modules_dir}/vertmp
	sync

	if ${vendor_dlkm_is_ext4}; then
		set_perm 0 0 0644 ${extract_vendor_dlkm_modules_dir}/*
		chcon u:object_r:vendor_file:s0 ${extract_vendor_dlkm_modules_dir}/*
		umount $extract_vendor_dlkm_dir
	else
		for f in "${extract_vendor_dlkm_modules_dir}"/*; do
			echo "vendor_dlkm/lib/modules/$(basename $f) 0 0 0644" >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config
		done
		echo '/vendor_dlkm/lib/modules/.+ u:object_r:vendor_file:s0' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts
		ui_print "- Repacking /vendor_dlkm image..."
		rm -f ${home}/vendor_dlkm.img
		mkfs_erofs ${extract_vendor_dlkm_dir}/vendor_dlkm ${home}/vendor_dlkm.img || \
			abort "! Failed to repack the vendor_dlkm image!"
		rm -rf ${extract_vendor_dlkm_dir}

		if [ "$(get_size ${home}/vendor_dlkm.img)" -gt "$vendor_dlkm_block_size" ]; then
			do_check_super_device_size=true
		else
			# Fill the erofs image file to the same size as the vendor_dlkm partition
			truncate -c -s $vendor_dlkm_block_size ${home}/vendor_dlkm.img
		fi
	fi

	if ${do_check_super_device_size}; then
		ui_print " "
		ui_print "- The generated image file is larger than the partition size."
		ui_print "- Checking super partition size..."
		check_super_device_size  # If the check here fails, it will be aborted directly.
		ui_print "- Pass!"
	fi

	unset do_check_super_device_size vendor_dlkm_block_size vendor_dlkm_is_ext4 extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir
fi

flash_boot # skip ramdisk repack
flash_generic vendor_dlkm

########## FLASH BOOT & VENDOR_DLKM END ##########

# Remove files no longer needed to avoid flashing again.
rm ${home}/Image
rm ${home}/boot.img
rm ${home}/boot-new.img
rm ${home}/vendor_dlkm.img

unset magisk_patched
rm ${home}/magisk_patched

touch ${home}/rollback_if_abort_flag

########## FLASH VENDOR_BOOT START ##########

## vendor_boot shell variables
block=vendor_boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=true

# reset for vendor_boot patching
reset_ak

# Try to fix vendor_ramdisk size and vendor_ramdisk table entry information that was corrupted by old versions of magiskboot.
${bin}/vendor_boot_fix "$block"
case $? in
	0) ui_print " " "- Successfully repaired the vendor_boot partition!";;
	2) ;;  # The vendor_boot partition is normal and does not need to be repaired.
	*) abort "! Failed to repair vendor_boot partition!";;
esac

# vendor_boot install
dump_boot

vendor_boot_modules_dir=${ramdisk}/lib/modules
rm ${vendor_boot_modules_dir}/*
cp ${home}/_vendor_boot_modules/* ${vendor_boot_modules_dir}/
set_perm 0 0 0644 ${vendor_boot_modules_dir}/*

mkdir ${home}/_dtbs
cp ${split_img}/dtb ${home}/_dtbs/dtb
dtb_img_splitted=$(${bin}/dtp -i ${home}/_dtbs/dtb | awk '{print $NF}') || abort "! Failed to split dtb file!"
ukee_dtb=
for dtb_file in $dtb_img_splitted; do
	if [ "$(${bin}/fdtget $dtb_file / model -ts)" == "Qualcomm Technologies, Inc. Ukee SoC" ]; then
		ukee_dtb="$dtb_file"
		break
	fi
done
[ -z "$ukee_dtb" ] && abort "! Can not found Ukee dtb file!"

# Copy the gpu frequency and voltage configuration of old dtb to the new dtb
if [ "$(sha1 $ukee_dtb)" != "$(sha1 ${home}/dtb)" ]; then
	copy_gpu_pwrlevels_conf "$ukee_dtb" ${home}/dtb
	sync
fi

rm -rf ${home}/_dtbs

unset dtb_img_splitted ukee_dtb

write_boot  # Since dtbo.img exists in ${home}, the dtbo partition will also be flashed at this time

########## FLASH VENDOR_BOOT END ##########

# Patch vbmeta
ui_print " "
for vbmeta_blk in /dev/block/by-name/vbmeta*; do
	ui_print "- Patching $(basename $vbmeta_blk) ..."
	${bin}/vbmeta-disable-verification $vbmeta_blk || {
		ui_print "! Failed to patch ${vbmeta_blk}!"
		ui_print "- If the device won't boot after the installation,"
		ui_print "  please manually disable AVB in TWRP."
	}
done

## end boot install
