SECTION = "bootloaders"

LICENSE = "GPLv2+"
LIC_FILES_CHKSUM = "file://Licenses/gpl-2.0.txt;md5=b234ee4d69f5fce4486a80fdaf4a4263"

SRCBRANCH = "imx_v2018.03_4.14.78_1.0.0_ga_var01"
UBOOT_SRC = "git://github.com/projectsas/uboot-imx.git;protocol=git"
SRC_URI = "${UBOOT_SRC};branch=${SRCBRANCH}"
SRCREV = "0f21a7fe76d7e554bf016923eaf9e53a940a06db"

S = "${WORKDIR}/git"
