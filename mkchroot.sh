#!/bin/bash

CHROOT_DIR=chroot

if [ ! -d "${CHROOT_DIR}" ]; then
	mkdir -p "${CHROOT_DIR}"
	curl http://cdimage.ubuntu.com/ubuntu-base/releases/16.04.4/release/ubuntu-base-16.04.4-base-amd64.tar.gz | tar zx -C "${CHROOT_DIR}"
fi
apt update
apt install --yes --no-install-recommends systemd-container fuse
systemd-nspawn -D "${CHROOT_DIR}" --bind "$(realpath mkaosp.sh):/bin/mkaosp.sh" --property=DeviceAllow=/dev/fuse /bin/bash --init-file <(echo 'mknod /dev/fuse c 10 229')
