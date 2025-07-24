# Android Image Unpacking and Repacking Script

- This is a Linux script for unpacking and repacking Android images with support for any filesystem (ext4, EROFS, F2FS). You can edit files in the extracted directories and then repack them as EROFS or ext4 while preserving xattrs (contexts, ownerships, and permissions). 

- It's like CRB Kitchen, but for Linux.


**Compatibility:** Debian/Ubuntu only. Arch/Fedora distros have issues with Android SELinux labels causing bootloops.

## Installing Dependencies

```bash
sudo apt autoremove erofs-utils

sudo apt install make automake libtool liblz4-dev git libfuse3-dev fuse3 uuid-dev -y

cd ~ && git clone https://github.com/erofs/erofs-utils.git

cd ~/erofs-utils

make clean

./autogen.sh

./configure --enable-fuse --enable-multithreading

make

sudo make install
```

## Usage

**Unpack image:**
```bash
sudo ./unpack-erofs-script.sh imagename.img
```

For f2fs support: `sudo modprobe f2fs`

**Repack as erofs/ext4:**
```bash
sudo ./repack-erofs-script.sh /path/to/extracted_imagename
```
