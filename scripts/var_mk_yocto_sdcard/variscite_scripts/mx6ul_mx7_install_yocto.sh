#!/bin/bash

# Installs Yocto to NAND/eMMC
set -e

. /usr/bin/echos.sh

IMGS_PATH=/opt/images/Yocto
KERNEL_IMAGE=zImage
KERNEL_DTB=""
STORAGE_DEV=""

if [[ $EUID != 0 ]] ; then
	red_bold_echo "This script must be run with super-user privileges"
	exit 1
fi

check_images()
{
	if [[ ! -f $IMGS_PATH/$SPL_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$SPL_IMAGE\" does not exist"
		exit 1
	fi

	if [[ ! -f $IMGS_PATH/$UBOOT_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$UBOOT_IMAGE\" does not exist"
		exit 1
	fi

	if [[ ! -f $IMGS_PATH/$KERNEL_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$KERNEL_IMAGE\" does not exist"
		exit 1
	fi

	if [[ $STORAGE_DEV == "nand" && ! -f $IMGS_PATH/$KERNEL_DTB ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$KERNEL_DTB\" does not exist"
		exit 1
	fi

	if [[ ! -f $IMGS_PATH/$ROOTFS_IMAGE ]] ; then
		red_bold_echo "ERROR: \"$IMGS_PATH/$ROOTFS_IMAGE\" does not exist"
		exit 1
	fi
}

# $1 is the full path of the config file
set_fw_env_config_to_emmc()
{
	sed -i "/mtd/ s/^#*/#/" $1
	sed -i "s/#*\/dev\/mmcblk./\/dev\/${block}/" $1
}

set_fw_utils_to_emmc_on_sd_card()
{
	# Adjust u-boot-fw-utils for eMMC on the SD card
	if [[ `readlink /sbin/fw_printenv` != "/sbin/fw_printenv-mmc" ]]; then
		ln -sf /sbin/fw_printenv-mmc /sbin/fw_printenv
	fi

	if [[ -f /etc/fw_env.config ]]; then
		set_fw_env_config_to_emmc /etc/fw_env.config
	fi
}

set_fw_utils_to_emmc_on_emmc()
{
	# Adjust u-boot-fw-utils for eMMC on the installed rootfs
	rm -f ${mountdir_prefix}${rootfspart}/sbin/fw_printenv-nand
	if [[ -f ${mountdir_prefix}${rootfspart}/sbin/fw_printenv-mmc ]]; then
		mv ${mountdir_prefix}${rootfspart}/sbin/fw_printenv-mmc ${mountdir_prefix}${rootfspart}/sbin/fw_printenv
	fi

	if [[ -f ${mountdir_prefix}${rootfspart}/etc/fw_env.config ]]; then
		set_fw_env_config_to_emmc ${mountdir_prefix}${rootfspart}/etc/fw_env.config
	fi
}

# $1 is the full path of the config file
set_fw_env_config_to_nand()
{
	sed -i "/mmcblk/ s/^#*/#/" $1
	sed -i "s/#*\/dev\/mtd/\/dev\/mtd/" $1

	MTD_DEV=`grep /dev/mtd $1 | cut -f1 | sed "s/\/dev\/*//"`
	MTD_ERASESIZE=$(printf 0x%x $(cat /sys/class/mtd/${MTD_DEV}/erasesize))
	awk -i inplace -v n=4 -v ERASESIZE="${MTD_ERASESIZE}" '/\/dev\/mtd/{$(n)=ERASESIZE}1' $1
}

set_fw_utils_to_nand_on_sd_card()
{
	# Adjust u-boot-fw-utils for NAND flash on the SD card
	if [[ `readlink /sbin/fw_printenv` != "/sbin/fw_printenv-nand" ]]; then
		ln -sf /sbin/fw_printenv-nand /sbin/fw_printenv
	fi

	if [[ -f /etc/fw_env.config ]]; then
		set_fw_env_config_to_nand /etc/fw_env.config
	fi
}

install_bootloader_to_nand()
{
	echo
	blue_underlined_bold_echo "Installing booloader"

	flash_erase /dev/mtd0 0 0 2> /dev/null
	kobs-ng init -x $IMGS_PATH/$SPL_IMAGE --search_exponent=1 -v > /dev/null

	flash_erase /dev/mtd1 0 0 2> /dev/null
	nandwrite -p /dev/mtd1 $IMGS_PATH/$UBOOT_IMAGE

	flash_erase /dev/mtd2 0 0 2> /dev/null
	sync
}

install_kernel_to_nand()
{
	echo
	blue_underlined_bold_echo "Installing kernel"

	flash_erase /dev/mtd3 0 0 2> /dev/null
	nandwrite -p /dev/mtd3 $IMGS_PATH/$KERNEL_IMAGE > /dev/null
	nandwrite -p /dev/mtd3 -s 0xbe0000 $IMGS_PATH/$KERNEL_DTB > /dev/null
	sync
}

install_rootfs_to_nand()
{
	echo
	blue_underlined_bold_echo "Installing UBI rootfs"

	ubiformat /dev/mtd4 -f $IMGS_PATH/$ROOTFS_IMAGE -y
	sync
}

delete_emmc()
{
	echo
	blue_underlined_bold_echo "Deleting current partitions"

	for ((i=0; i<=10; i++))
	do
		if [[ -e ${node}${part}${i} ]] ; then
			dd if=/dev/zero of=${node}${part}${i} bs=1024 count=1024 2> /dev/null || true
		fi
	done
	sync

	((echo d; echo 1; echo d; echo 2; echo d; echo 3; echo d; echo w) | fdisk $node &> /dev/null) || true
	sync

	dd if=/dev/zero of=$node bs=1M count=4
	sync; sleep 1
}

create_emmc_parts()
{
	echo
	blue_underlined_bold_echo "Creating new partitions"

	SECT_SIZE_BYTES=`cat /sys/block/${block}/queue/hw_sector_size`
	PART1_FIRST_SECT=`expr 4 \* 1024 \* 1024 \/ $SECT_SIZE_BYTES`
	PART2_FIRST_SECT=`expr $((4 + 16)) \* 1024 \* 1024 \/ $SECT_SIZE_BYTES`
	PART1_LAST_SECT=`expr $PART2_FIRST_SECT - 1`

	(echo n; echo p; echo $bootpart; echo $PART1_FIRST_SECT; echo $PART1_LAST_SECT; echo t; echo c; \
	 echo n; echo p; echo $rootfspart; echo $PART2_FIRST_SECT; echo; \
	 echo p; echo w) | fdisk -u $node > /dev/null

	sync; sleep 1
	fdisk -u -l $node
}

create_emmc_swupdate_parts()
{
	echo
	blue_underlined_bold_echo "Creating new partitions"

	TOTAL_SECTORS=`cat /sys/class/block/${block}/size`
	SECT_SIZE_BYTES=`cat /sys/block/${block}/queue/hw_sector_size`

	BOOTLOAD_RESERVE_SIZE=4

	BOOTLOAD_RESERVE_SIZE_BYTES=$((BOOTLOAD_RESERVE_SIZE * 1024 * 1024))
	ROOTFS1_PART_START=$((BOOTLOAD_RESERVE_SIZE_BYTES / SECT_SIZE_BYTES))

	DATA_SIZE_BYTES=$((DATA_SIZE * 1024 * 1024))
	DATA_PART_SIZE=$((DATA_SIZE_BYTES / SECT_SIZE_BYTES))

	ROOTFS1_PART_SIZE=$((( TOTAL_SECTORS - ROOTFS1_PART_START - DATA_PART_SIZE ) / 2))
	ROOTFS2_PART_SIZE=$ROOTFS1_PART_SIZE

	ROOTFS2_PART_START=$((ROOTFS1_PART_START + ROOTFS1_PART_SIZE))
	DATA_PART_START=$((ROOTFS2_PART_START + ROOTFS2_PART_SIZE))

	ROOTFS1_PART_END=$((ROOTFS2_PART_START - 1))
	ROOTFS2_PART_END=$((DATA_PART_START - 1))

	(echo n; echo p; echo $rootfspart;  echo $ROOTFS1_PART_START; echo $ROOTFS1_PART_END; \
	 echo n; echo p; echo $rootfs2part; echo $ROOTFS2_PART_START; echo $ROOTFS2_PART_END; \
	 echo n; echo p; echo $datapart;    echo $DATA_PART_START; echo; \
	 echo p; echo w) | fdisk -u $node > /dev/null

	sync; sleep 1
	fdisk -u -l $node
}

format_emmc_parts()
{
	echo
	blue_underlined_bold_echo "Formatting partitions"

	if [[ $swupdate == 0 ]] ; then
		mkfs.vfat ${node}${part}${bootpart} -n ${FAT_VOLNAME}
		mkfs.ext4 ${node}${part}${rootfspart} -L rootfs
	elif [[ $swupdate == 1 ]] ; then
		mkfs.ext4 ${node}${part}${rootfspart}  -L rootfs1
		mkfs.ext4 ${node}${part}${rootfs2part} -L rootfs2
		mkfs.ext4 ${node}${part}${datapart}    -L data
	fi
	sync; sleep 1
}

install_bootloader_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing booloader"

	dd if=${IMGS_PATH}/${SPL_IMAGE} of=${node} bs=1K seek=1; sync
	dd if=${IMGS_PATH}/${UBOOT_IMAGE} of=${node} bs=1K seek=69; sync

	if [[ $VARSOMMX7_VARIANT == "-m4" || $swupdate == 1 ]] ; then
		echo
		echo "Setting U-Boot enviroment variables"
		set_fw_utils_to_emmc_on_sd_card

		if [[ $VARSOMMX7_VARIANT == "-m4" ]] ; then
			fw_setenv use_m4 yes  2> /dev/null
		fi

		if [[ $swupdate == 1 ]] ; then
			fw_setenv mmcrootpart 1  2> /dev/null
			fw_setenv bootdir /boot
		fi
	fi
}

install_kernel_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing kernel to BOOT partition"

	mkdir -p ${mountdir_prefix}${bootpart}
	mount -t vfat ${node}${part}${bootpart}		${mountdir_prefix}${bootpart}
	cd ${IMGS_PATH}
	cp -v ${KERNEL_DTBS}	${mountdir_prefix}${bootpart}
	cp -v ${KERNEL_IMAGE}	${mountdir_prefix}${bootpart}
	cd - >/dev/null
	sync
	umount ${node}${part}${bootpart}
}

install_rootfs_to_emmc()
{
	echo
	blue_underlined_bold_echo "Installing rootfs"

	mkdir -p ${mountdir_prefix}${rootfspart}
	mount ${node}${part}${rootfspart} ${mountdir_prefix}${rootfspart}
	printf "Extracting files"
	tar xpf ${IMGS_PATH}/${ROOTFS_IMAGE} -C ${mountdir_prefix}${rootfspart} --checkpoint=.1200
	echo

	set_fw_utils_to_emmc_on_emmc

	echo
	sync
	umount ${node}${part}${rootfspart}
}

stop_udev()
{
	if [ -f /lib/systemd/system/systemd-udevd.service ]; then
		systemctl -q mask --runtime systemd-udevd
		systemctl -q stop systemd-udevd
	else
		/etc/init.d/udev stop
	fi
}

start_udev()
{
	if [ -f /lib/systemd/system/systemd-udevd.service ]; then
		systemctl -q unmask --runtime systemd-udevd
		systemctl -q start systemd-udevd
	else
		/etc/init.d/udev start
	fi
}

usage()
{
	echo
	echo "This script installs Yocto on the SOM's internal storage device"
	echo
	echo " Usage: $0 OPTIONS"
	echo
	echo " OPTIONS:"
	echo " -b <dart6ul|som6ul|mx7>  Board model (DART-6UL/VAR-SOM-6UL/VAR-SOM-MX7) - optional, autodetected if not provided."
	echo " -r <nand|emmc>		storage device (NAND flash/eMMC) - optional, autodetected if not provided."
	echo " -v <wifi|sd>		DART-6UL/VAR-SOM-6UL mmc0 device (WiFi/SD card) - mandatory in case of 6UL with NAND flash; ignored otherwise."
	echo " -m			VAR-SOM-MX7 optional Cortex-M4 support; ignored in case of 6UL."
	echo " -u			create two rootfs partitions (for swUpdate double-copy) - ignored in case of NAND storage device."
	echo
}

finish()
{
	echo
	blue_bold_echo "Yocto installed successfully"
	exit 0
}


blue_underlined_bold_echo "*** Variscite MX6UL/MX6ULL/MX6ULZ/MX7 Yocto eMMC/NAND Recovery ***"
echo

VARSOMMX7_VARIANT=""
swupdate=0

SOC=`cat /sys/bus/soc/devices/soc0/soc_id`
if [[ $SOC == i.MX6UL* ]] ; then
	if grep -iq DART /sys/devices/soc0/machine ; then
		BOARD=dart6ul
	else
		BOARD=som6ul
	fi

	if [[ -d /sys/bus/platform/devices/1806000.gpmi-nand ]] ; then
		STORAGE_DEV=nand
	else
		STORAGE_DEV=emmc
	fi
elif [[ $SOC == i.MX7D ]] ; then
	BOARD=mx7

	if [[ -d /sys/bus/platform/devices/33002000.gpmi-nand ]] ; then
		STORAGE_DEV=nand
	else
		STORAGE_DEV=emmc
	fi
fi

while getopts :b:r:v:mu OPTION;
do
	case $OPTION in
	b)
		BOARD=$OPTARG
		;;
	r)
		STORAGE_DEV=$OPTARG
		;;
	v)
		MX6UL_MMC0_DEV=$OPTARG
		;;
	m)
		VARSOMMX7_VARIANT=-m4
		;;
	u)
		swupdate=1
		;;
	*)
		usage
		exit 1
		;;
	esac
done

STR=""

if [[ $BOARD == "dart6ul" ]] ; then
	STR="DART-6UL ($SOC)"
elif [[ $BOARD == "som6ul" ]] ; then
	STR="VAR-SOM-6UL ($SOC)"
elif [[ $BOARD == "mx7" ]] ; then
	STR="VAR-SOM-MX7"
else
	usage
	exit 1
fi

printf "Board: "
blue_bold_echo $STR

if [[ $STORAGE_DEV == "nand" ]] ; then
	STR="NAND"
	MTD_ERASESIZE=`cat /sys/class/mtd/mtd4/erasesize`
	if [[ $MTD_ERASESIZE == 131072 ]] ; then
		ROOTFS_IMAGE=rootfs_128kbpeb.ubi
	else
		ROOTFS_IMAGE=rootfs_256kbpeb.ubi
	fi
elif [[ $STORAGE_DEV == "emmc" ]] ; then
	STR="eMMC"
	ROOTFS_IMAGE=rootfs.tar.gz
else
	usage
	exit 1
fi

printf "Installing to internal storage device: "
blue_bold_echo $STR

if [[ $BOARD == *6ul ]] ; then
	if [[ $STORAGE_DEV == "nand" ]] ; then
		if [[ $MX6UL_MMC0_DEV == "wifi" ]] ; then
			STR="WiFi (no SD card)"
		elif [[ $MX6UL_MMC0_DEV == "sd" ]] ; then
			STR="SD card (no WiFi)"
		else
			usage
			exit 1
		fi
		printf "With support for:  "
		blue_bold_echo "$STR"
	fi

	if [[ $SOC == i.MX6UL ]] ; then
		soc="imx6ul"
	elif [[ $SOC == i.MX6ULL ]] ; then
		soc="imx6ull"
	elif [[ $SOC == i.MX6ULZ ]] ; then
		soc="imx6ulz"
	fi
	if [[ $BOARD == "dart6ul" ]] ; then
		som="var-dart"
		carrier="6ulcustomboard"
	elif [[ $BOARD == "som6ul" ]] ; then
		som="var-som"
		carrier="concerto-board"
	fi
	if [[ $MX6UL_MMC0_DEV == "sd" ]] ; then
		mx6ul_mmc0_dev="sd-card"
	elif [[ $MX6UL_MMC0_DEV == "wifi" ]] ; then
		mx6ul_mmc0_dev="wifi"
	fi
fi

if [[ $STORAGE_DEV == "nand" ]] ; then
	SPL_IMAGE=SPL-nand
	UBOOT_IMAGE=u-boot.img-nand

	if [[ $BOARD == *6ul ]] ; then
		KERNEL_DTB="${soc}-${som}-${carrier}-${STORAGE_DEV}-${mx6ul_mmc0_dev}.dtb"
	elif [[ $BOARD == "mx7" ]] ; then
		KERNEL_DTB="imx7d-var-som-nand${VARSOMMX7_VARIANT}.dtb"
	fi

	printf "Installing Device Tree file: "
	blue_bold_echo $KERNEL_DTB

	printf "Installing rootfs image: "
	blue_bold_echo $ROOTFS_IMAGE

	if [[ ! -e /dev/mtd0 ]] ; then
		red_bold_echo "ERROR: Can't find NAND flash device."
		red_bold_echo "Please verify you are using the correct options for your SOM."
		exit 1
	fi

	check_images
	install_bootloader_to_nand
	install_kernel_to_nand
	install_rootfs_to_nand
elif [[ $STORAGE_DEV == "emmc" ]] ; then
	if [[ $swupdate == 1 ]] ; then
		blue_bold_echo "Creating two rootfs partitions"
	fi

	SPL_IMAGE=SPL-sd
	UBOOT_IMAGE=u-boot.img-sd

	if [[ $BOARD == *6ul ]] ; then
		block=mmcblk1
		KERNEL_DTBS="${soc}-${som}-${carrier}-${STORAGE_DEV}-*.dtb"
		FAT_VOLNAME=BOOT-VAR6UL
	elif [[ $BOARD == "mx7" ]] ; then
		block=mmcblk2
		KERNEL_DTBS="imx7d-var-som-emmc*.dtb"
		FAT_VOLNAME=BOOT-VARMX7
	fi
	node=/dev/${block}
	if [[ ! -b $node ]] ; then
		red_bold_echo "ERROR: Can't find eMMC device ($node)."
		red_bold_echo "Please verify you are using the correct options for your SOM."
		exit 1
	fi
	part=p
	mountdir_prefix=/run/media/${block}${part}

	if [[ $swupdate == 0 ]] ; then
		bootpart=1
		rootfspart=2
	elif [[ $swupdate == 1 ]] ; then
		bootpart=none
		rootfspart=1
		rootfs2part=2
		datapart=3

		DATA_SIZE=200
	fi

	check_images
	umount ${node}${part}*  2> /dev/null || true
	stop_udev
	delete_emmc
	if [[ $swupdate == 0 ]] ; then
		create_emmc_parts
	elif [[ $swupdate == 1 ]] ; then
		create_emmc_swupdate_parts
	fi
	format_emmc_parts
	install_bootloader_to_emmc
	install_rootfs_to_emmc

	if [[ $swupdate == 0 ]] ; then
		install_kernel_to_emmc
	fi
	start_udev
fi

finish
