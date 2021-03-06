#!/bin/bash

main()
{
	ARGC="${#}" && ARGV="${@}"
	if [ ${ARGC} -ne 1 ]; then usage_exit; fi
	
	# Set variables
	CHROOT_DIR=chroot
	DEVICE=taimen
	RELEASE_BUCKET=aosp
	ANDROID_VERSION=8.1.0
	BUILD_DIR=/root/aosp_build
	AOSP_BUILD=$(curl -s https://developers.google.com/android/images | grep -A1 "${DEVICE}" | egrep '[a-zA-Z]+ [0-9]{4}\)' | grep "${ANDROID_VERSION}" | tail -1 | cut -d"(" -f2 | cut -d"," -f1)
	AOSP_BRANCH=$(curl -s https://source.android.com/setup/start/build-numbers | grep -A1 "${AOSP_BUILD}" | tail -1 | cut -f2 -d">"|cut -f1 -d"<")	
	
	# Run action
	ACTION="${1}"
	case "${ACTION}" in
		init)
			apt update && apt install --yes --no-install-recommends systemd-container fuse s3cmd unzip
			if [ ! -d "${CHROOT_DIR}" ]; then mkchroot; fi
			;;
		build)
			digitalocean_get_keys
			chroot_build
			;;
		release)
			digitalocean_backup_keys
			digitalocean_release
			;;
		*)
			usage_exit
	esac
}

usage_exit()
{
	exit 1
}

mkchroot()
{
	echo "Setting up chroot..."
	mkdir -p "${CHROOT_DIR}"
	curl http://cdimage.ubuntu.com/ubuntu-base/releases/16.04.4/release/ubuntu-base-16.04.4-base-amd64.tar.gz | tar zx -C "${CHROOT_DIR}"
}

chroot_build()
{
	systemd-nspawn -D "${CHROOT_DIR}" --bind "$(realpath mkaosp.sh):/bin/mkaosp.sh" --property=DeviceAllow=/dev/fuse /bin/bash -c "mknod /dev/fuse c 10 229; AOSP_BUILD=${AOSP_BUILD} AOSP_BRANCH=${AOSP_BRANCH} /bin/mkaosp.sh init taimen; /bin/mkaosp.sh build taimen"
}

digitalocean_get_keys()
{
	if [ "$(s3cmd ls s3://${RELEASE_BUCKET}/keys/${DEVICE} | wc -l)" -ne 0 ] && [ ! -d "${CHROOT_DIR}/${BUILD_DIR}/keys/${DEVICE}" ]; then
		echo "Fetching build keys from s3..."
		s3cmd get --recursive "s3://${RELEASE_BUCKET}/keys/${DEVICE}" "${CHROOT_DIR}/${BUILD_DIR}/keys/"
	fi
}

digitalocean_backup_keys()
{
	if [ "$(s3cmd ls s3://${RELEASE_BUCKET}/keys/${DEVICE} | wc -l)" -eq 0 ] && [ -d "${CHROOT_DIR}/${BUILD_DIR}/keys/${DEVICE}" ]; then
		echo "Pushing build keys to s3..."
		s3cmd put --recursive "${CHROOT_DIR}/${BUILD_DIR}/keys/${DEVICE}" "s3://${RELEASE_BUCKET}/keys/"
	fi
}

digitalocean_release()
{
	pushd "${CHROOT_DIR}/${BUILD_DIR}/out"
	build_date="$(< build_number.txt)"
	build_timestamp="$(unzip -p "release-${DEVICE}-${build_date}/${DEVICE}-ota_update-${build_date}.zip" META-INF/com/android/metadata | grep 'post-timestamp' | cut --delimiter "=" --fields 2)"
	
	# Remove old ota
	old_metadata="$(s3cmd get --no-progress s3://${RELEASE_BUCKET}/taimen-stable -)"
	old_date="$(cut -d ' ' -f 1 <<< "${old_metadata}")"
	if [ ! -z "${old_date}" ]; then s3cmd rm "s3://${RELEASE_BUCKET}/${DEVICE}-ota_update-${old_date}.zip"; fi

	# Upload new metadata and ota
	echo "${build_date} ${build_timestamp} ${AOSP_BUILD}" | s3cmd put - "s3://${RELEASE_BUCKET}/${DEVICE}-stable" --acl-public
	echo "${AOSP_BUILD}" | s3cmd put - "s3://${RELEASE_BUCKET}/${DEVICE}-vendor" --acl-public
	echo "${BUILD_TRUE_TIMESTAMP}" | s3cmd put - "s3://${RELEASE_BUCKET}/${DEVICE}-stable-true-timestamp" --acl-public
	s3cmd put "${CHROOT_DIR}/${BUILD_DIR}/out/release-${DEVICE}-${build_date}/${DEVICE}-ota_update-${build_date}.zip" "s3://${RELEASE_BUCKET}" --acl-public
    s3cmd put "${CHROOT_DIR}/${BUILD_DIR}/out/release-${DEVICE}-${build_date}/${DEVICE}-factory-${build_date}.tar.xz" "s3://${RELEASE_BUCKET}/${DEVICE}-factory-latest.tar.xz" --acl-private
}

main "${@}"
