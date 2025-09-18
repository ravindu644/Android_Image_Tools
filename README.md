# Android Image Unpacking and Repacking Script

- This is a Linux script for unpacking and repacking Android images with support for any filesystem (ext4, EROFS, F2FS). You can edit files in the extracted directories and then repack them as EROFS or ext4 while preserving xattrs (contexts, ownerships, and permissions). 

- It's like CRB Kitchen, but for Linux.


**Compatibility:** Debian/Ubuntu only. Arch/Fedora distros have issues with Android SELinux labels causing bootloops.

## How to use ?

**Run the android_image_tools.sh as root to see what happens !**

```bash
sudo ./android_image_tools.sh
```
