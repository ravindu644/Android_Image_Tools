**How to unpack an image?**
- Any filesystem is supported as the input, including ext4, erofs, and f2fs (make sure to run `sudo modprobe f2fs` for f2fs support).

```bash

sudo ./unpack-erofs-script.sh system.img

```


**How to repack the image as erofs?**

```bash

sudo ./repack-erofs-script.sh /path/to/extracted_imagename

```

**Notes:**

- You might need to uninstall the existing `erofs-utils` and compile it from source if you want to change compression levels.
- Just press Enter when it asks for a compression level (for now — will fix it later).
