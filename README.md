### aosp_builder

# About
This repository contains scripts for building AOSP with verified boot and OTA updates.

# Requirements
The scripts run on Ubuntu 16.04. They install dependencies from the Ubuntu repos. YMMV on other distros.
`mkchroot.sh` uses systemd-nspawn and hence requires a system running systemd.

# Usage
`mkaosp.sh` will build android in $HOME/aosp_build by default
`mkchroot.sh` will create a minimal environment separate from the rest of the system ideal for building AOSP

```
./mkchroot.sh
# Inside chroot
/bin/mkaosp.sh init <device>
/bin/mkaosp.sh build <device>
# Releases can be found in ${BUILD_DIR}/out
```
