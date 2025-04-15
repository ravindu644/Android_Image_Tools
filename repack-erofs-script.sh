#!/bin/bash
# EROFS Image Repacker Script with Enhanced Attribute Restoration
# Usage: ./repack_erofs.sh <extracted_folder_path>

set -e

# Define color codes
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
BOLD="\033[1m"
RESET="\033[0m"

# Banner function
print_banner() {
  echo -e "${BOLD}${GREEN}"
  echo "┌───────────────────────────────────────────┐"
  echo "│         Repack EROFS - by @ravindu644     │"
  echo "└───────────────────────────────────────────┘"
  echo -e "${RESET}"
}

print_banner

# Check if script is run as root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"
  exit 1
fi

# Check if mkfs.erofs is installed
if ! command -v mkfs.erofs &> /dev/null; then
  echo -e "${RED}mkfs.erofs command not found. Please install erofs-utils package.${RESET}"
  echo -e "For Ubuntu/Debian: sudo apt install erofs-utils"
  echo -e "For other distributions, check your package manager.${RESET}"
  exit 1
fi

# Check if extracted folder is provided
if [ $# -ne 1 ]; then
  echo -e "${YELLOW}Usage: $0 <extracted_folder_path>${RESET}"
  echo -e "Example: $0 extracted_vendor"
  exit 1
fi

EXTRACT_DIR="$1"

# Remove trailing slash if present
EXTRACT_DIR=${EXTRACT_DIR%/}

# Check if extracted directory exists
if [ ! -d "$EXTRACT_DIR" ]; then
  echo -e "${RED}Error: Directory '$EXTRACT_DIR' not found.${RESET}"
  exit 1
fi

PARTITION_NAME=$(basename "$EXTRACT_DIR" | sed 's/^extracted_//')
OUTPUT_IMG="${PARTITION_NAME}_repacked.img"
FS_CONFIG_FILE="${EXTRACT_DIR}/fs-config.txt"
FILE_CONTEXTS_FILE="${EXTRACT_DIR}/file_contexts.txt"
SYMLINKS_FILE="${EXTRACT_DIR}/symlinks.txt"

# Check if file attribute files exist
if [ ! -f "$FS_CONFIG_FILE" ]; then
  echo -e "${YELLOW}Warning: FS config file not found at ${FS_CONFIG_FILE}.${RESET}"
  echo -e "${YELLOW}File permissions and ownership will not be applied.${RESET}"
fi

if [ ! -f "$FILE_CONTEXTS_FILE" ]; then
  echo -e "${YELLOW}Warning: File contexts file not found at ${FILE_CONTEXTS_FILE}.${RESET}"
  echo -e "${YELLOW}SELinux contexts will not be applied.${RESET}"
fi

# Find modified or new files compared to the attribute records
echo -e "${BLUE}Detecting modified or new files...${RESET}"
detect_modified_files() {
  echo -e "${BLUE}Analyzing files...${RESET}"
  spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
  spin=0
  
  # Get list of all files in the directory (excluding metadata files)
  find "$EXTRACT_DIR" -type f -not -path "$EXTRACT_DIR/fs-config.txt" \
    -not -path "$EXTRACT_DIR/file_contexts.txt" \
    -not -path "$EXTRACT_DIR/symlinks.txt" \
    -printf "%P\n" | sort > /tmp/all_files.txt &
    
  while kill -0 $! 2>/dev/null; do
    echo -ne "\r${BLUE}[${spinner[$((spin++))]}] Scanning files${RESET}"
    spin=$((spin % 10))
    sleep 0.1
  done
  
  total_files=$(wc -l < /tmp/all_files.txt)
  echo -e "\r${GREEN}[✓] Found ${total_files} files to process${RESET}"
  
  if [ -f "$FS_CONFIG_FILE" ]; then
    grep -v "^#" "$FS_CONFIG_FILE" | awk '{print $1}' | sort > /tmp/config_files.txt
    comm -23 /tmp/all_files.txt /tmp/config_files.txt > /tmp/new_files.txt
    find "$EXTRACT_DIR" -type d -not -path "$EXTRACT_DIR" -printf "%P\n" | sort > /tmp/all_dirs.txt
    grep -v "^#" "$FS_CONFIG_FILE" | grep -v " 0 0 644 " | awk '{print $1}' | sort > /tmp/special_paths.txt
    comm -23 /tmp/all_dirs.txt /tmp/special_paths.txt > /tmp/new_dirs.txt
  else
    cp /tmp/all_files.txt /tmp/new_files.txt
    find "$EXTRACT_DIR" -type d -not -path "$EXTRACT_DIR" -printf "%P\n" > /tmp/new_dirs.txt
  fi
  
  new_files=$(wc -l < /tmp/new_files.txt)
  new_dirs=$(wc -l < /tmp/new_dirs.txt)
  
  if [ $new_files -gt 0 ] || [ $new_dirs -gt 0 ]; then
    echo -e "${BLUE}Found ${new_files} new files and ${new_dirs} new directories${RESET}"
  fi
}

# Default SELinux contexts for common Android paths
apply_android_defaults() {
  local path="$1"
  
  # Set a proper default context
  local default_context=""
  local default_perm="644"
  local default_uid="0"
  local default_gid="0"
  local is_dir=false
  
  if [ -d "$EXTRACT_DIR/$path" ]; then
    is_dir=true
    default_perm="755"
  fi
  
  # Android-specific path handling
  case "$path" in
    app/*|priv-app/*)
      if [[ "$path" == *".apk" ]]; then
        default_context="u:object_r:system_file:s0"
      elif [[ "$path" == *"/" ]] || $is_dir; then
        default_context="u:object_r:system_file:s0"
      fi
      ;;
    bin/*|xbin/*)
      default_context="u:object_r:system_file:s0"
      ;;
    etc/*)
      default_context="u:object_r:system_file:s0"
      ;;
    lib/*|lib64/*)
      default_context="u:object_r:system_file:s0"
      ;;
    vendor/*)
      default_context="u:object_r:vendor_file:s0"
      ;;
    *)
      default_context="u:object_r:system_file:s0"
      ;;
  esac
  
  # Always ensure we have a default context
  if [ -z "$default_context" ]; then
    default_context="u:object_r:system_file:s0"
  fi
  
  echo "$default_context $default_uid $default_gid $default_perm"
}

# Apply attributes to new files based on similar files in the same directory
apply_attributes() {
  if [ ! -s "/tmp/new_files.txt" ] && [ ! -s "/tmp/new_dirs.txt" ]; then
    echo -e "${GREEN}No new files or directories to process.${RESET}"
    return
  fi
  
  echo -e "${BLUE}Applying attributes to new files and directories...${RESET}"
  
  # Process directories first (parent before child)
  if [ -s "/tmp/new_dirs.txt" ]; then
    # Sort directories by depth (process parents first)
    sort -t/ -k1,1 /tmp/new_dirs.txt > /tmp/new_dirs_sorted.txt
    
    while read -r dir; do
      # Skip if empty
      [ -z "$dir" ] && continue
      
      # Find a parent directory
      parent=$(dirname "$dir")
      if [ "$parent" = "." ]; then
        parent_attrs=""
      else
        parent_attrs=$(grep "^$parent " "$FS_CONFIG_FILE" 2>/dev/null | head -1)
      fi
      
      # Find a sibling directory
      sibling_dir=$(grep "^${parent}/[^/]*$" "$FS_CONFIG_FILE" 2>/dev/null | grep " 755 " | head -1 | awk '{print $1}')
      sibling_attrs=""
      if [ -n "$sibling_dir" ]; then
        sibling_attrs=$(grep "^$sibling_dir " "$FS_CONFIG_FILE" 2>/dev/null | head -1)
      fi
      
      # If we found parent or sibling attributes, use them
      if [ -n "$parent_attrs" ]; then
        uid=$(echo "$parent_attrs" | awk '{print $2}')
        gid=$(echo "$parent_attrs" | awk '{print $3}')
        mode="755"  # Default mode for directories
      elif [ -n "$sibling_attrs" ]; then
        uid=$(echo "$sibling_attrs" | awk '{print $2}')
        gid=$(echo "$sibling_attrs" | awk '{print $3}')
        mode="755"  # Default mode for directories
      else
        # Use Android defaults
        defaults=$(apply_android_defaults "$dir")
        context=$(echo "$defaults" | cut -d' ' -f1)
        uid=$(echo "$defaults" | cut -d' ' -f2)
        gid=$(echo "$defaults" | cut -d' ' -f3)
        mode=$(echo "$defaults" | cut -d' ' -f4)
      fi
      
      # Apply ownership and permissions
      echo -e "${BLUE}Setting directory $dir to $uid:$gid mode $mode${RESET}"
      chown "$uid:$gid" "$EXTRACT_DIR/$dir"
      chmod "$mode" "$EXTRACT_DIR/$dir"
      
      # Add to fs-config
      echo "$dir $uid $gid $mode capabilities=0x0" >> "$FS_CONFIG_FILE"
      
      # Get SELinux context
      if [ -f "$FILE_CONTEXTS_FILE" ]; then
        # Try to find context for parent or sibling directory
        if [ -n "$parent" ] && [ "$parent" != "." ]; then
          parent_context=$(grep "^$parent " "$FILE_CONTEXTS_FILE" 2>/dev/null | head -1 | awk '{print $2}')
        fi
        
        if [ -n "$sibling_dir" ]; then
          sibling_context=$(grep "^$sibling_dir " "$FILE_CONTEXTS_FILE" 2>/dev/null | head -1 | awk '{print $2}')
        fi
        
        # Use parent context, or sibling context, or default
        if [ -n "$parent_context" ]; then
          context="$parent_context"
        elif [ -n "$sibling_context" ]; then
          context="$sibling_context"
        else
          defaults=$(apply_android_defaults "$dir")
          context=$(echo "$defaults" | cut -d' ' -f1)
        fi
        
        # Apply SELinux context
        echo -e "${BLUE}Setting directory $dir context to $context${RESET}"
        if command -v chcon &> /dev/null; then
          chcon "$context" "$EXTRACT_DIR/$dir" 2>/dev/null || true
        fi
        
        # Add to file_contexts
        echo "$dir $context" >> "$FILE_CONTEXTS_FILE"
      fi
    done < /tmp/new_dirs_sorted.txt
  fi
  
  # Now process files
  if [ -s "/tmp/new_files.txt" ]; then
    while read -r file; do
      # Skip if empty
      [ -z "$file" ] && continue
      
      dir=$(dirname "$file")
      basename=$(basename "$file")
      
      # Find files with same extension in the same directory
      file_ext="${basename##*.}"
      if [ "$file_ext" != "$basename" ]; then
        similar_file=$(grep "^$dir/[^/]*\\.$file_ext$" "$FS_CONFIG_FILE" 2>/dev/null | head -1 | awk '{print $1}')
      else
        similar_file=""
      fi
      
      if [ -n "$similar_file" ]; then
        # Get attributes from similar file
        similar_attrs=$(grep "^$similar_file " "$FS_CONFIG_FILE" 2>/dev/null | head -1)
        uid=$(echo "$similar_attrs" | awk '{print $2}')
        gid=$(echo "$similar_attrs" | awk '{print $3}')
        mode=$(echo "$similar_attrs" | awk '{print $4}')
      else
        # Try to get directory attributes
        dir_attrs=$(grep "^$dir$" "$FS_CONFIG_FILE" 2>/dev/null | head -1)
        if [ -n "$dir_attrs" ]; then
          uid=$(echo "$dir_attrs" | awk '{print $2}')
          gid=$(echo "$dir_attrs" | awk '{print $3}')
          # Files usually 644, executables 755
          if [[ "$basename" == *.sh || "$basename" == *.bin || -x "$EXTRACT_DIR/$file" ]]; then
            mode="755"
          else
            mode="644"
          fi
        else
          # Use Android defaults
          defaults=$(apply_android_defaults "$file")
          context=$(echo "$defaults" | cut -d' ' -f1)
          uid=$(echo "$defaults" | cut -d' ' -f2)
          gid=$(echo "$defaults" | cut -d' ' -f3)
          mode=$(echo "$defaults" | cut -d' ' -f4)
        fi
      fi
      
      # Apply ownership and permissions
      echo -e "${BLUE}Setting file $file to $uid:$gid mode $mode${RESET}"
      chown "$uid:$gid" "$EXTRACT_DIR/$file"
      chmod "$mode" "$EXTRACT_DIR/$file"
      
      # Add to fs-config
      echo "$file $uid $gid $mode capabilities=0x0" >> "$FS_CONFIG_FILE"
      
      # Handle SELinux context
      if [ -f "$FILE_CONTEXTS_FILE" ]; then
        context=""
        if [ -n "$similar_file" ]; then
          similar_context=$(grep "^$similar_file " "$FILE_CONTEXTS_FILE" 2>/dev/null | head -1 | awk '{print $2}')
          [ -n "$similar_context" ] && context="$similar_context"
        fi
        
        if [ -z "$context" ] && [ -n "$dir" ] && [ "$dir" != "." ]; then
          dir_context=$(grep "^$dir " "$FILE_CONTEXTS_FILE" 2>/dev/null | head -1 | awk '{print $2}')
          [ -n "$dir_context" ] && context="$dir_context"
        fi
        
        if [ -z "$context" ]; then
          defaults=$(apply_android_defaults "$file")
          context=$(echo "$defaults" | cut -d' ' -f1)
        fi
        
        # Ensure we have a context
        if [ -z "$context" ]; then
          context="u:object_r:system_file:s0"
        fi
        
        # Apply SELinux context
        echo -e "${BLUE}Setting file $file context to $context${RESET}"
        if command -v chcon &> /dev/null; then
          chcon "$context" "$EXTRACT_DIR/$file" 2>/dev/null || true
        fi
        
        # Add to file_contexts
        echo "$file $context" >> "$FILE_CONTEXTS_FILE"
      fi
    done < /tmp/new_files.txt
  fi
}

# Apply attributes to existing files from config
restore_attributes() {
  echo -e "${BLUE}Preparing for attribute restoration...${RESET}"
  chown -R root:root "$EXTRACT_DIR"
  
  if [ ! -f "$FS_CONFIG_FILE" ]; then
    echo -e "${YELLOW}No fs-config file found, skipping attribute restoration.${RESET}"
    return
  fi
  
  total_items=$(grep -v "^#" "$FS_CONFIG_FILE" | wc -l)
  spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
  spin=0
  processed=0
  
  echo -e "${BLUE}Restoring file attributes...${RESET}"
  
  # Process all entries with progress spinner
  grep -v "^#" "$FS_CONFIG_FILE" | while read -r line; do
    processed=$((processed + 1))
    percentage=$((processed * 100 / total_items))
    
    file=$(echo "$line" | awk '{print $1}')
    uid=$(echo "$line" | awk '{print $2}')
    gid=$(echo "$line" | awk '{print $3}')
    mode=$(echo "$line" | awk '{print $4}')
    
    if [ -e "$EXTRACT_DIR/$file" ]; then
      chown "$uid:$gid" "$EXTRACT_DIR/$file" 2>/dev/null
      chmod "$mode" "$EXTRACT_DIR/$file" 2>/dev/null
    fi
    
    # Update progress every 100 items
    if [ $((processed % 100)) -eq 0 ]; then
      echo -ne "\r${BLUE}[${spinner[$((spin++))]}] Progress: ${percentage}% (${processed}/${total_items})${RESET}"
      spin=$((spin % 10))
    fi
  done
  echo -e "\r${GREEN}[✓] Attributes restored successfully${RESET}"
  
  # SELinux contexts restoration with progress
  if [ -f "$FILE_CONTEXTS_FILE" ] && command -v chcon &> /dev/null; then
    echo -e "${BLUE}Restoring SELinux contexts...${RESET}"
    total_contexts=$(grep -v "^#" "$FILE_CONTEXTS_FILE" | wc -l)
    processed=0
    spin=0
    
    grep -v "^#" "$FILE_CONTEXTS_FILE" | while read -r line; do
      processed=$((processed + 1))
      percentage=$((processed * 100 / total_contexts))
      
      file=$(echo "$line" | awk '{print $1}')
      context=$(echo "$line" | cut -d' ' -f2-)
      
      if [ -e "$EXTRACT_DIR/$file" ] || [ -L "$EXTRACT_DIR/$file" ]; then
        chcon "$context" "$EXTRACT_DIR/$file" 2>/dev/null
      fi
      
      if [ $((processed % 100)) -eq 0 ]; then
        echo -ne "\r${BLUE}[${spinner[$((spin++))]}] SELinux: ${percentage}% (${processed}/${total_contexts})${RESET}"
        spin=$((spin % 10))
      fi
    done
    echo -e "\r${GREEN}[✓] SELinux contexts restored${RESET}"
  fi
  
  # Symlinks restoration with progress
  if [ -f "$SYMLINKS_FILE" ]; then
    echo -e "${BLUE}Restoring symlinks...${RESET}"
    total_links=$(grep -v "^#" "$SYMLINKS_FILE" | grep " -> " | wc -l)
    processed=0
    spin=0
    
    grep -v "^#" "$SYMLINKS_FILE" | grep " -> " | while read -r line; do
      processed=$((processed + 1))
      percentage=$((processed * 100 / total_links))
      
      link_path=$(echo "$line" | awk -F " -> " '{print $1}')
      link_target=$(echo "$line" | awk -F " -> " '{print $2}')
      
      mkdir -p "$(dirname "$EXTRACT_DIR/$link_path")" 2>/dev/null
      rm -f "$EXTRACT_DIR/$link_path" 2>/dev/null
      ln -sf "$link_target" "$EXTRACT_DIR/$link_path"
      
      # Only show progress for larger numbers of symlinks
      if [ $total_links -gt 100 ] && [ $((processed % 50)) -eq 0 ]; then
        echo -ne "\r${BLUE}[${spinner[$((spin++))]}] Symlinks: ${percentage}% (${processed}/${total_links})${RESET}"
        spin=$((spin % 10))
      fi
    done
    
    # Clear the progress line before showing completion
    echo -ne "\r${BLUE}[${spinner[$((spin % 10))]}] Symlinks: 100% (${total_links}/${total_links})${RESET}"
    echo -e "\n${GREEN}[✓] Restored ${total_links} symlinks${RESET}"
  fi
}

# Detect and process new files
detect_modified_files
apply_attributes
restore_attributes

# Ask for compression method
echo -e "\n${BLUE}${BOLD}Select compression method:${RESET}"
echo -e "1. none (default)"
echo -e "2. lz4"
echo -e "3. lz4hc"
read -p "Enter your choice [1-3]: " COMP_CHOICE

case $COMP_CHOICE in
  2)
    COMPRESSION="-zlz4"
    ;;
  3)
    COMPRESSION="-zlz4hc"
    ;;
  *)
    COMPRESSION=""
    echo -e "${BLUE}Using no compression.${RESET}"
    ;;
esac

# Ask for compression level if using compression
if [[ "$COMPRESSION" == *"lz4"* ]]; then
  echo -e "\n${BLUE}${BOLD}Select compression level:${RESET}"
  echo -e "For lz4: 1-9 (default: 6, higher = better compression but slower)"
  echo -e "For lz4hc: 1-12 (default: 9, higher = better compression but slower)"
  read -p "Enter compression level: " COMP_LEVEL
  
  # Validate compression level
  if [[ "$COMPRESSION" == "-zlz4" && "$COMP_LEVEL" =~ ^[1-9]$ ]]; then
    COMPRESSION="$COMPRESSION,level=$COMP_LEVEL"
  elif [[ "$COMPRESSION" == "-zlz4hc" && "$COMP_LEVEL" =~ ^([1-9]|1[0-2])$ ]]; then
    COMPRESSION="$COMPRESSION,level=$COMP_LEVEL"
  elif [[ -n "$COMP_LEVEL" ]]; then
    echo -e "${YELLOW}Invalid compression level. Using default level.${RESET}"
  fi
fi

# Create the EROFS image with simplest command
MKFS_CMD="mkfs.erofs"

# Add compression if selected
if [ -n "$COMPRESSION" ]; then
  MKFS_CMD="$MKFS_CMD $COMPRESSION"
fi

# Add output and input paths
MKFS_CMD="$MKFS_CMD $OUTPUT_IMG $EXTRACT_DIR"

# Show the command
echo -e "\n${BLUE}Executing command:${RESET}"
echo -e "${BOLD}$MKFS_CMD${RESET}\n"

# Create the EROFS image
echo -e "${BLUE}Creating EROFS image... This may take some time.${RESET}\n"
eval $MKFS_CMD

# Check if image creation was successful
if [ $? -eq 0 ]; then
  echo -e "\n${GREEN}${BOLD}Successfully created EROFS image: $OUTPUT_IMG${RESET}"
  echo -e "${BLUE}Image size: $(du -h "$OUTPUT_IMG" | cut -f1)${RESET}"
  
  # Transfer ownership back to actual user
  if [ -n "$SUDO_USER" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$EXTRACT_DIR"
    chown "$SUDO_USER:$SUDO_USER" "$OUTPUT_IMG"
  fi
else
  echo -e "\n${RED}Error occurred during image creation.${RESET}"
  exit 1
fi

# Clean up temporary files
rm -f /tmp/all_files.txt /tmp/config_files.txt /tmp/new_files.txt
rm -f /tmp/all_dirs.txt /tmp/special_paths.txt /tmp/new_dirs.txt /tmp/new_dirs_sorted.txt

echo -e "\n${GREEN}${BOLD}Done!${RESET}"
