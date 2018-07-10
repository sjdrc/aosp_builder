#!/bin/bash

# TODO store this an actual xml file somewhere
LOCAL_MANIFEST=\
'<?xml version="1.0" encoding="UTF-8"?>
<manifest>
	<remote name="github" fetch="https://github.com/" />
	<remote name="fdroid" fetch="https://gitlab.com/fdroid/" />

	<project path="script" name="RattlesnakeOS/script" remote="github" revision="master" />
	<project path="packages/apps/Updater" name="RattlesnakeOS/platform_packages_apps_Updater" remote="github" revision="master" />
	<project path="vendor/android-prepare-vendor" name="anestisb/android-prepare-vendor" remote="github" revision="master" />
	
	<project path="packages/apps/F-Droid" name="fdroidclient" remote="fdroid" revision="refs/tags/1.2.2" />
	<project path="packages/apps/F-DroidPrivilegedExtension" name="privileged-extension" remote="fdroid" revision="refs/tags/0.2.8" />

 	<remove-project name="platform/packages/apps/Browser2" />
 	<remove-project name="platform/packages/apps/Calendar" />
 	<remove-project name="platform/packages/apps/QuickSearchBox" />
 	<remove-project name="platform/packages/apps/Camera2" />
 	<remove-project name="platform/packages/apps/ExactCalculator" />
 	<remove-project name="platform/packages/apps/Music" />
</manifest>'

log() { printf "[LOG][$(date "+%Y-%m-%d %H:%M:%S")] %s\n" "$*"; }
log_err() { printf "[ERR][$(date "+%Y-%m-%d %H:%M:%S")] %s\n" "$*" >&2; }
usage() { printf "Usage: $0 action device\n\taction: {init|build}\n\tdevice: {sailfish|marlin|walleye|taimen}\n"; }
fdpe_hash() { keytool -list -printcert -file "$1" | grep 'SHA256:' | tr --delete ':' | cut --delimiter ' ' --fields 3; }
init_repo() { pushd "${BUILD_DIR}"; repo init -q --manifest-url 'https://android.googlesource.com/platform/manifest' --manifest-branch "${AOSP_BRANCH}" --depth 1; popd; }
sync_repo() { pushd "${BUILD_DIR}";	repo sync -q -c --no-tags --no-clone-bundle --jobs $(nproc); popd; }

########################################
# Sets up build environment
# TODO better install for android-sdk
########################################
setup_env()
{
	log "Setting up environment..."
	apt -qq update
	apt -qq install --yes --no-install-recommends openjdk-8-jdk git-core gnupg flex bison gperf build-essential zip curl zlib1g-dev gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev libx11-dev lib32z-dev libgl1-mesa-dev libxml2-utils xsltproc unzip ccache python-networkx liblz4-tool repo gperf jq wget rsync fuseext2 bsdmainutils cgpt
	
	if [ ! -d "/usr/local/android-sdk" ]; then
		log "Setting up Android SDK..."
		wget "https://dl.google.com/android/repository/sdk-tools-linux-4333796.zip" -O "/tmp/sdk-tools-linux.zip"
		mkdir -p "/usr/local/android-sdk"
		unzip "/tmp/sdk-tools-linux.zip" -d "/usr/local/android-sdk"
		yes | /usr/local/android-sdk/tools/bin/sdkmanager --licenses
	fi
	
	git config --get --global user.name || git config --global user.name 'unknown'
	git config --get --global user.email || git config --global user.email 'unknown@localhost'
	git config --global color.ui true	
	mkdir -p "${BUILD_DIR}"
}

########################################
# Sets up vendor files
# TODO Marlin kernel, additional devices
########################################
init_vendor()
{
	log "Setting up vendor files..."
	target_device=
	case "${DEVICE}" in
		marlin|taimen)
			target_device="${DEVICE}"
			;;
		sailfish)
			target_device='marlin'
			;;
		walleye)
			target_device='muskie'
			;;
		*)
			log_err "Somehow setup_vendor has been given an invalid device of: ${DEVICE}. This shouldn't have happened"
			exit 1
	esac
	if [ ! -d "${BUILD_DIR}/vendor/google_devices/${target_device}" ]; then
		mkdir -p "${BUILD_DIR}/vendor/google_devices"
		sed -i -e "s/USE_DEBUGFS=true/USE_DEBUGFS=false/" -e "s/# SYS_TOOLS/SYS_TOOLS/" -e "s/# _UMOUNT=/_UMOUNT=/" "${BUILD_DIR}/vendor/android-prepare-vendor/execute-all.sh"
		bash "${BUILD_DIR}/vendor/android-prepare-vendor/execute-all.sh" --yes --device "${DEVICE}" --buildID "${AOSP_BUILD}" --output "${BUILD_DIR}/vendor/android-prepare-vendor"
		mv "${BUILD_DIR}/vendor/android-prepare-vendor/${DEVICE}/$(tr '[:upper:]' '[:lower:]' <<< "${AOSP_BUILD}")/vendor/google_devices/${target_device}" "${BUILD_DIR}/vendor/google_devices"
	fi
}

########################################
# Generate keys used for signing build
# TODO Add additional devices
########################################
gen_keys()
{
	log "Generating signing keys..."
	mkdir --parents "${BUILD_DIR}/keys/${DEVICE}"
	pushd "${BUILD_DIR}/keys/${DEVICE}"
	for key in {releasekey,platform,shared,media,verity} ; do
		# make_key exits with unsuccessful code 1 instead of 0, need ! to negate
		! "${BUILD_DIR}/development/tools/make_key" "${key}" '/CN=RattlesnakeOS'
	done
	popd

	case "${DEVICE}" in
		marlin|sailfish)
			make -j 20 generate_verity_key
			"${BUILD_DIR}/out/host/linux-x86/bin/generate_verity_key" -convert "${BUILD_DIR}/keys/${DEVICE}/verity.x509.pem" "${BUILD_DIR}/keys/${DEVICE}/verity_key"
			make clobber
			openssl x509 -outform der -in "${BUILD_DIR}/keys/${DEVICE}/verity.x509.pem" -out "${BUILD_DIR}/keys/${DEVICE}/verity_user.der.x509"
			;;
		walleye|taimen)
			openssl genrsa -out "${BUILD_DIR}/keys/${DEVICE}/avb.pem" 2048
			"${BUILD_DIR}/external/avb/avbtool" extract_public_key --key "${BUILD_DIR}/keys/${DEVICE}/avb.pem" --output "${BUILD_DIR}/keys/${DEVICE}/avb_pkmd.bin"
			;;
		*)
			log_err "Somehow gen_keys has been given an invalid device of: ${DEVICE}. This shouldn't have happened"
	esac
}

########################################
# Apply custom changes to android sources
# TODO Use patch.d/*.patch files
########################################
apply_patches()
{
	log "Patching AOSP sources..."
	# Remove unwanted apps from build
	sed -i -e '/webview \\/d' "${BUILD_DIR}/build/make/target/product/core_minimal.mk"
	sed -i -e '/Browser2/d' "${BUILD_DIR}/build/make/target/product/core.mk"
	sed -i -e '/Calendar/d' "${BUILD_DIR}/build/make/target/product/core.mk"
	sed -i -e '/QuickSearchBox/d' "${BUILD_DIR}/build/make/target/product/core.mk"	
	sed -i -e '/Camera2/d' "${BUILD_DIR}/build/make/target/product/core.mk"	
	sed -i -e '/ExactCalculator/d' "${BUILD_DIR}/build/make/target/product/core.mk"	
	sed -i -e '/Music/d' "${BUILD_DIR}/build/make/target/product/core.mk"	

	# Include external apps into build
	sed -i -e "\$aPRODUCT_PACKAGES += Updater" "${BUILD_DIR}/build/make/target/product/core.mk"
	sed -i -e "\$aPRODUCT_PACKAGES += F-DroidPrivilegedExtension" "${BUILD_DIR}/build/make/target/product/core.mk"
	sed -i -e "\$aPRODUCT_PACKAGES += F-Droid" "${BUILD_DIR}/build/make/target/product/core.mk"

	# Use Chromium as webview
	sed -i -e "s/Android WebView/Chromium/" -e "s/com.android.webview/org.chromium.chrome/" ${BUILD_DIR}/frameworks/base/core/res/res/xml/config_webview_packages.xml

	# Fix Updater URL
	sed -i -e "s@s3bucket@${OTA_URL}/@g" "${BUILD_DIR}/packages/apps/Updater/res/values/config.xml"
 
	# Patch F-Droid
	yes | /usr/local/android-sdk/tools/bin/sdkmanager --licenses
	echo "sdk.dir=/usr/local/android-sdk" > "${BUILD_DIR}/packages/apps/F-Droid/local.properties"
	echo "sdk.dir=/usr/local/android-sdk" > "${BUILD_DIR}/packages/apps/F-Droid/app/local.properties"
	sed -i -e "s/gradle assembleRelease/..\/gradlew assembleRelease/" "${BUILD_DIR}/packages/apps/F-Droid/Android.mk"
	pushd "${BUILD_DIR}/packages/apps/F-Droid"
	./gradlew assembleRelease || true
	popd

	# Patch F-Droid Priviliged Extension
	unofficial_releasekey_hash=$(fdpe_hash "${BUILD_DIR}/keys/${DEVICE}/releasekey.x509.pem")
	unofficial_platform_hash=$(fdpe_hash "${BUILD_DIR}/keys/${DEVICE}/platform.x509.pem")
	whitelist_file="${BUILD_DIR}/packages/apps/F-DroidPrivilegedExtension/app/src/main/java/org/fdroid/fdroid/privileged/ClientWhitelist.java"
	sed -i -e "s/43238d512c1e5eb2d6569f4a3afbf5523418b82e0a3ed1552770abb9a9c9ccab/KEY/p" "${whitelist_file}"
	sed -i -e "0,/KEY/{s/KEY\")/${unofficial_releasekey_hash}\"),/}" "${whitelist_file}"
	sed -i -e "0,/KEY/{s/KEY/${unofficial_platform_hash}/}" "${whitelist_file}"

	# Apply signature spoofing patch from microg
	pushd "${BUILD_DIR}/frameworks/base"
	curl https://raw.githubusercontent.com/microg/android_packages_apps_GmsCore/master/patches/android_frameworks_base-O.patch | git apply -v || true
	popd
}

########################################
# Run a build on checked out sources
# TODO use ccache option for builds
########################################
build_aosp()
{
	log "Building AOSP..."
	yes | /usr/local/android-sdk/tools/bin/sdkmanager --licenses
	pushd "${BUILD_DIR}"
	source "${BUILD_DIR}/script/setup.sh"
	choosecombo "release" "aosp_${DEVICE}" "user"
	make -j $(nproc) target-files-package
	make -j $(nproc) brillo_update_payload
	"${BUILD_DIR}/script/release.sh" "$DEVICE"
	popd
}

########################################
# Run the full script
# TODO check bash vars are set
########################################
main()
{
	ARGC=$#
	ARGV="$@"
	if [ ${ARGC} -ne 2 ]; then
		usage
		exit 1
	fi
	
	OTA_URL=https://aosp.sgp1.digitaloceanspaces.com
	BUILD_DIR="${BUILD_DIR:=/root/aosp_build}"
	
	DEVICE=$2
	case "${DEVICE}" in
		sailfish|marlin|walleye|taimen)
			# Trigger or mark device specific shit here maybe?
			;;
		*)
			log_err "Unsupported device ${DEVICE}"
			exit 1
	esac

	ACTION=$1
	case "${ACTION}" in
		init)
			if [ -z ${AOSP_BUILD} ] || [ -z ${AOSP_BRANCH} ]; then echo "AOSP_BUILD and AOSP_BRANCH must be set for init!"; exit 1; fi
			setup_env
			log "Cloning repos - this may take a while..."
			init_repo
			mkdir -p "${BUILD_DIR}/.repo/local_manifests"
			echo "${LOCAL_MANIFEST}" > "${BUILD_DIR}/.repo/local_manifests/rattlesnake-os.xml"
			init_vendor
			if [ ! -d "${BUILD_DIR}/keys/${DEVICE}" ]; then	gen_keys; fi
			;;
		build)
			if [ ! -d "${BUILD_DIR}/.repo" ]; then log_err "Call init first!"; exit 1; fi
			sync_repo
			apply_patches
			build_aosp
			;;
		*)
			usage
			exit 1
	esac
}

set -e
main "$@"
