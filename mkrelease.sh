#!/bin/bash

digitalocean_get_keys()
{
	if [ "$(s3cmd ls s3://${RELEASE_BUCKET}/keys/${DEVICE} | wc -l)" -ne 0 ] && [ ! -d "${CHROOT_DIR}/${BUILD_DIR}/keys/${DEVICE}" ]; then
		echo "Fetching build keys from s3..."
		s3cmd get --recursive "s3://${RELEASE_BUCKET}/keys/${DEVICE}" "${CHROOT_DIR}/${BUILD_DIR}/keys/${DEVICE}"
	fi
}

digitalocean_backup_keys()
{
	if [ "$(s3cmd ls s3://${RELEASE_BUCKET}/keys/${DEVICE} | wc -l)" -eq 0 ] && [ -d "${CHROOT_DIR}/${BUILD_DIR}/keys/${DEVICE}" ]; then
		echo "Pushing build keys to s3..."
		s3cmd put --recursive "${CHROOT_DIR}/${BUILD_DIR}/keys/${DEVICE}" "s3://${RELEASE_BUCKET}/keys/${DEVICE}"
	fi
}

digitalocean_release()
{
	pushd "${BUILD_DIR}/out"
	build_date="$(< build_number.txt)"
	build_timestamp="$(unzip -p "release-${DEVICE}-${build_date}/${DEVICE}-ota_update-${build_date}.zip" META-INF/com/android/metadata | grep 'post-timestamp' | cut --delimiter "=" --fields 2)"
	
	# Remove old ota
	old_metadata="$(s3cmd get --no-progress s3://sjdrc/taimen-stable -)"
	old_date="$(cut -d ' ' -f 1 <<< "${old_metadata}")"
	s3cmd rm "s3://${RELEASE_BUCKET}/${DEVICE}-ota_update-${old_date}.zip" || true

	# Upload new metadata and ota
	echo "${build_date} ${build_timestamp} ${AOSP_BUILD}" | s3cmd put - "s3://${RELEASE_BUCKET}/${DEVICE}-stable" --acl-public
	echo "${BUILD_TRUE_TIMESTAMP}" | s3cmd put - "s3://${RELEASE_BUCKET}/${DEVICE}-stable-true-timestamp" --acl-public
	s3cmd put "${BUILD_DIR}/out/release-${DEVICE}-${build_date}/${DEVICE}-ota_update-${build_date}.zip" "s3://${RELEASE_BUCKET}" --acl-public
    s3cmd put "${BUILD_DIR}/out/release-${DEVICE}-${build_date}/${DEVICE}-factory-${build_date}.tar.xz" "s3://${RELEASE_BUCKET}/${DEVICE}-factory-latest.tar.xz" --acl-private
}

main()
{
	CHROOT_DIR=chroot
	DEVICE=taimen
	RELEASE_BUCKET=aosp
	ANDROID_VERSION=8.1.0
	AOSP_BUILD=$(curl -s https://developers.google.com/android/images | grep -A1 "${DEVICE}" | egrep '[a-zA-Z]+ [0-9]{4}\)' | grep "${ANDROID_VERSION}" | tail -1 | cut -d"(" -f2 | cut -d"," -f1)
	AOSP_BRANCH=$(curl -s https://source.android.com/setup/start/build-numbers | grep -A1 "${AOSP_BUILD}" | tail -1 | cut -f2 -d">"|cut -f1 -d"<")	
	
	if [ ! -d "${CHROOT_DIR}" ]; then
		mkdir -p "${CHROOT_DIR}"
		curl http://cdimage.ubuntu.com/ubuntu-base/releases/16.04.4/release/ubuntu-base-16.04.4-base-amd64.tar.gz | tar zx -C "${CHROOT_DIR}"
		apt update
		apt install --yes --no-install-recommends systemd-container fuse s3cmd
	fi
	digitalocean_get_keys
	systemd-nspawn -D "${CHROOT_DIR}" --bind "$(realpath mkaosp.sh):/bin/mkaosp.sh" --property=DeviceAllow=/dev/fuse /bin/bash -c "mknod /dev/fuse c 10 229; AOSP_BUILD=${AOSP_BUILD} AOSP_BRANCH=${AOSP_BRANCH} /bin/mkaosp.sh init taimen; /bin/mkaosp.sh build taimen"
	digitalocean_backup_keys
	digitalocean_release
}

main
