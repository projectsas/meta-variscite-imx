SECTION = "bootloaders"

LICENSE = "GPLv2+"
LIC_FILES_CHKSUM = "file://Licenses/gpl-2.0.txt;md5=b234ee4d69f5fce4486a80fdaf4a4263"

SRCBRANCH = "imx_v2018.03_4.14.78_1.0.0_ga_var01"
UBOOT_SRC = "git://github.com/projectsas/uboot-imx.git;protocol=git"
SRC_URI = "${UBOOT_SRC};branch=${SRCBRANCH}"
SRCREV = "4e1e605fd1d478aae034798440390e78f8c4f5ac"

S = "${WORKDIR}/git"
