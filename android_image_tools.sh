#!/bin/bash
# Android Image Tools - by @ravindu644
#
# A comprehensive, stable wrapper for unpacking and repacking Android images.

# --- Global Settings & Color Codes ---
trap 'cleanup_and_exit' INT TERM EXIT

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
UNPACK_SCRIPT_PATH="${SCRIPT_DIR}/.bin/unpack-erofs.sh"
REPACK_SCRIPT_PATH="${SCRIPT_DIR}/.bin/repack-erofs.sh"
SUPER_SCRIPT_PATH="${SCRIPT_DIR}/.bin/super-tools.sh"

WORKSPACE_DIRS=("INPUT_IMAGES" "EXTRACTED_IMAGES" "REPACKED_IMAGES" "SUPER_TOOLS")

RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"; BLUE="\033[0;34m"; BOLD="\033[1m"; RESET="\033[0m"
AIT_CHOICE_INDEX=0; AIT_SELECTED_ITEM=""

# --- Core Functions ---
print_banner() {
    echo -e "${BOLD}${GREEN}"
    echo "┌──────────────────────────────────────────────────┐"
    echo "│     Android Image Tools - by @ravindu644         │"
    echo "└──────────────────────────────────────────────────┘"
    echo -e "${RESET}"
}

print_usage() {
    if [ -n "$1" ]; then echo -e "\n${RED}${BOLD}Error: Invalid argument '$1'${RESET}"; fi
    local script_name
    script_name=$(basename "$0")
    echo -e "\n${YELLOW}Usage:${RESET}"
    echo -e "  Interactive Mode: ${BOLD}sudo ./${script_name}${RESET}"
    echo -e "  Non-Interactive:  ${BOLD}sudo ./${script_name} --conf=<path_to_config_file>${RESET}"
    exit 1
}

sudo_cleanup_temp_dirs() {
    local temp_dirs
    temp_dirs=$(find /tmp -mindepth 1 -maxdepth 1 \( -name "repack-*" -o -name "*_mount" -o -name "*_raw.img" -o -name "super_unpack_*" -o -name "ait_super_*" \) -print0 2>/dev/null)
    if [ -n "$temp_dirs" ]; then
        echo "$temp_dirs" | xargs -0 sudo rm -rf
    fi
}

cleanup_and_exit() {
    tput cnorm
    sudo_cleanup_temp_dirs
    echo -e "\n${YELLOW}Exiting Android Image Tools.${RESET}"
    exit 130
}

check_distro() {
    if ! command -v dpkg &>/dev/null || ! command -v apt &>/dev/null; then
        echo -e "\n${RED}${BOLD}Error: Unsupported Operating System Detected.${RESET}"
        echo -e "${YELLOW}This script is designed specifically for Debian-based distributions (like Ubuntu)${RESET}"
        echo -e "${YELLOW}which use 'apt' and 'dpkg' for package management.${RESET}"
        echo -e "\nThis is to ensure proper handling of SELinux contexts, which can be inconsistent"
        echo -e "on other distributions (e.g., Arch, Fedora), leading to repacking errors."
        exit 1
    fi
}

check_dependencies() {
    local missing_pkgs=()
    local erofs_utils_missing=false
    local REQUIRED_PACKAGES=("android-sdk-libsparse-utils" "build-essential" "automake" "autoconf" "libtool" "git" "fuse3" "e2fsprogs" "pv" "liblz4-dev" "uuid-dev" "libfuse3-dev")
    
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -s "$pkg" &> /dev/null; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    if ! command -v mkfs.erofs &>/dev/null; then
        erofs_utils_missing=true
    fi
    
    if [ ${#missing_pkgs[@]} -eq 0 ] && [ "$erofs_utils_missing" = false ]; then
        return 0 # All dependencies are present, exit silently
    fi
    
    # If we reach here, some dependencies are missing.
    clear
    print_banner
    echo -e "\n${RED}${BOLD}Warning: Missing required dependencies.${RESET}"
    
    if [ ${#missing_pkgs[@]} -gt 0 ]; then
        echo -e "\n${YELLOW}The following packages are missing:${RESET}"
        echo "  - ${missing_pkgs[*]}"
    fi

    if [ "$erofs_utils_missing" = true ]; then
        echo -e "\n${YELLOW}The 'erofs-utils' build tools are also missing.${RESET}"
    fi

    read -rp "$(echo -e "\n${BLUE}Do you want to attempt automatic installation? (y/N): ${RESET}")" choice
    
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo -e "\n${BLUE}Starting automatic installation...${RESET}"
        set -e
        
        if [ ${#missing_pkgs[@]} -gt 0 ]; then
            local unique_pkgs=$(echo "${missing_pkgs[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')
            echo -e "\n${BLUE}Updating package lists...${RESET}"
            sudo apt update
            echo -e "\n${BLUE}Installing required packages: $unique_pkgs${RESET}"
            sudo apt install -y $unique_pkgs
        fi

        if [ "$erofs_utils_missing" = true ]; then
            echo -e "\n${BLUE}Cloning and compiling 'erofs-utils'...${RESET}"
            local erofs_tmp_dir
            erofs_tmp_dir=$(mktemp -d)
            git clone https://github.com/erofs/erofs-utils.git "$erofs_tmp_dir"
            cd "$erofs_tmp_dir"
            ./autogen.sh
            ./configure --enable-fuse
            make
            sudo make install
            cd "$SCRIPT_DIR"
            rm -rf "$erofs_tmp_dir"
            echo -e "${GREEN}'erofs-utils' installed successfully.${RESET}"
        fi
        
        set +e
        echo -e "\n${GREEN}${BOLD}[✓] All dependencies should now be installed.${RESET}"
        read -rp "Press Enter to continue..."
    else
        echo -e "\n${YELLOW}Automatic installation declined.${RESET}"
        echo -e "Please install the dependencies manually and re-run the script."
        exit 1
    fi
}

create_workspace() {
    local ALL_DIRS=("${WORKSPACE_DIRS[@]}" "CONFIGS")
    for dir in "${ALL_DIRS[@]}"; do
        mkdir -p "$dir"
        if [ -n "$SUDO_USER" ]; then
            chown -R "$SUDO_USER:${SUDO_GROUP:-$SUDO_USER}" "$dir"
        fi
    done
}

generate_config_file() {
    local config_path="default.conf"
    echo -e "\n${BLUE}Generating fully documented configuration file at '${config_path}'...${RESET}"
    cat > "$config_path" <<'EOF'
# --- Android Image Tools Configuration File ---
# USAGE: sudo ./android_image_tools.sh --conf=your_config.conf
#
# --- [DOCUMENTATION] ---
# ACTION: "unpack", "repack", "super_unpack", or "super_repack". (Mandatory)
#
# == For single partitions ==
# INPUT_IMAGE: Image in 'INPUT_IMAGES' to unpack.
# EXTRACT_DIR: Directory name for extracted files in 'EXTRACTED_IMAGES'.
# SOURCE_DIR: Source directory in 'EXTRACTED_IMAGES' to repack.
# OUTPUT_IMAGE: Output filename in 'REPACKED_IMAGES'.
#
# == For super partitions ==
# PROJECT_NAME: The name of the project folder inside 'SUPER_TOOLS'.
#   - For super_unpack: The name of the project to create.
#   - For super_repack: The name of the existing project to repack.
#
# == General Repack Settings ==
# FILESYSTEM: "ext4" or "erofs".
# CREATE_SPARSE_IMAGE: "true" to create a flashable .sparse.img, "false" for raw .img.
# COMPRESSION_MODE: For erofs - "none", "lz4", "lz4hc", "deflate".
# COMPRESSION_LEVEL: For erofs lz4hc(0-12) or deflate(0-9).
# MODE: For ext4 - "flexible" or "strict".
#
# == EXT4 Flexible Mode Settings (Optional) ==
# EXT4_OVERHEAD_PERCENT: Percentage of free space to add. Default is "5".

# --- Default Settings Begin Here ---
ACTION=repack
INPUT_IMAGE=system.img
EXTRACT_DIR=extracted_system
SOURCE_DIR=extracted_system
OUTPUT_IMAGE=system_new.img
FILESYSTEM=ext4
CREATE_SPARSE_IMAGE=true
MODE=flexible
EXT4_OVERHEAD_PERCENT=5
EOF
    echo -e "\n${GREEN}${BOLD}[✓] Configuration file generated successfully.${RESET}"
}

display_final_image_size() {
    local image_path="$1"
    if [ ! -f "$image_path" ]; then return; fi
    local file_size
    file_size=$(stat -c %s "$image_path" | numfmt --to=iec-i --suffix=B --padding=7)
    echo -e "\n${GREEN}${BOLD}Final Image Size: ${file_size}${RESET}"
}

# --- Interactive Menu Functions ---
select_option() {
    local header="$1"
    shift
    local no_clear=false
    local options
    if [[ "${!#}" == "--no-clear" ]]; then
        no_clear=true
        options=("${@:1:$#-1}")
    else
        options=("$@")
    fi

    local current=0
    local is_first_iteration=true
    local options_height=${#options[@]}
    
    tput civis
    if [ "$no_clear" = false ]; then
        clear
        print_banner
    fi
    echo -e "\n${BOLD}${header}${RESET}\n"
    
    while true; do
        if [ "$is_first_iteration" = false ]; then
            tput cuu "$options_height"
        fi
        
        for i in "${!options[@]}"; do
            tput el
            local option_text="${options[$i]}"
            local is_danger=false
            if [[ "$option_text" == "Cleanup Workspace" || "$option_text" == "Yes, DELETE EVERYTHING" ]]; then
                is_danger=true
            fi
            
            if [ $i -eq $current ]; then
                if [ "$is_danger" = true ]; then
                    echo -e "  ${RED}▶ $option_text${RESET}"
                else
                    echo -e "  ${GREEN}▶ $option_text${RESET}"
                fi
            else
                echo -e "    $option_text"
            fi
        done
        
        is_first_iteration=false
        read -rsn1 key
        if [[ "$key" == $'\x1b' ]]; then
            read -rsn2 key
            case "$key" in
                '[A') current=$(( (current - 1 + ${#options[@]}) % ${#options[@]} )) ;;
                '[B') current=$(( (current + 1) % ${#options[@]} )) ;;
            esac
        elif [[ "$key" == "" ]]; then
            break
        fi
    done
    
    tput cnorm
    AIT_CHOICE_INDEX=$current
}

select_item() {
    local header="$1"
    local search_path="$2"
    local item_type="$3"
    local add_back_option=true
    if [[ "$4" == "--no-back" ]]; then
        add_back_option=false
    fi
    local items=()
    local find_args=()

    case "$item_type" in

        # This one specifically excludes any file starting with 'super'
        single_partition_image)
            find_args=(-type f \( -name '*.img' -o -name '*.img.raw' \) -not -name 'super*.img')
            ;;
        # This one is for finding ALL images, including super.img
        image_file)
            find_args=(-type f \( -name '*.img' -o -name '*.img.raw' \))
            ;;
        dir)
            find_args=(-type d)
            ;;
        *)
            find_args=\( -type f -o -type d \)
            ;;
    esac
    
    while IFS= read -r item; do
        items+=("$(basename "$item")")
    done < <(find "$search_path" -mindepth 1 -maxdepth 1 "${find_args[@]}" 2>/dev/null)
    
    if [ ${#items[@]} -eq 0 ]; then
        clear; print_banner
        echo -e "\n${YELLOW}Warning: No items of type '${item_type}' found in '${search_path}'.${RESET}"
        read -rp $'\nPress Enter to return...'
        return 1
    fi
    
    if [ "$add_back_option" = true ]; then
        items+=("Back")
    fi
    select_option "$header" "${items[@]}"
    
    if [ "$add_back_option" = true ] && [ "$AIT_CHOICE_INDEX" -eq $((${#items[@]} - 1)) ]; then
        return 1
    fi
    
    AIT_SELECTED_ITEM="${search_path}/${items[$AIT_CHOICE_INDEX]}"
    return 0
}

export_repack_config() {
    local source_dir="$1" output_image="$2" fs="$3" repack_mode="$4" erofs_comp="$5" erofs_level="$6" create_sparse="$7" overhead_percent="$8"
    
    mkdir -p "CONFIGS"
    clear; print_banner
    
    local partition_name
    partition_name=$(basename "$source_dir" | sed 's/^extracted_//')
    local default_conf_name="${partition_name}_repack.conf"
    
    read -rp "$(echo -e ${BLUE}"Enter filename for preset [${BOLD}${default_conf_name}${BLUE}]: "${RESET})" conf_filename
    conf_filename=${conf_filename:-$default_conf_name}
    
    local final_conf_path="CONFIGS/$conf_filename"
    local full_source_path
    full_source_path=$(realpath "$source_dir")
    local full_output_path
    full_output_path="$(realpath "$(dirname "$output_image")")/$(basename "$output_image")"
    
    {
        echo "# --- Android Image Tools Repack Configuration ---"
        echo "ACTION=repack"
        echo "SOURCE_DIR=$full_source_path"
        echo "OUTPUT_IMAGE=$full_output_path"
        echo "FILESYSTEM=$fs"
        echo "CREATE_SPARSE_IMAGE=$create_sparse"
        
        if [ "$fs" == "erofs" ]; then
            echo "COMPRESSION_MODE=${erofs_comp:-none}"
            if [[ "$erofs_comp" == "lz4hc" || "$erofs_comp" == "deflate" ]]; then
                echo "COMPRESSION_LEVEL=${erofs_level:-9}"
            fi
        else
            echo "MODE=${repack_mode:-flexible}"
            if [ "$repack_mode" == "flexible" ]; then
                echo "EXT4_OVERHEAD_PERCENT=${overhead_percent:-5}"
            fi
        fi
    } > "$final_conf_path"
    
    echo -e "\n${GREEN}${BOLD}[✓] Settings successfully exported to '${final_conf_path}'.${RESET}"
    read -rp $'\nPress Enter to return to the summary...'
}

# --- START: REPLACE THIS ENTIRE FUNCTION ---
cleanup_workspace() {
    clear; print_banner
    
    local total_bytes=0
    local dirs_to_scan=("${WORKSPACE_DIRS[@]}" "CONFIGS")
    local workspace_bytes
    workspace_bytes=$(du -sb "${dirs_to_scan[@]}" 2>/dev/null | awk '{s+=$1} END {print s}')
    total_bytes=$((total_bytes + ${workspace_bytes:-0}))
    
    local temp_files_list
    
    temp_files_list=$(find /tmp -mindepth 1 -maxdepth 1 \( -name "repack-*" -o -name "*_mount" -o -name "*_raw.img" -o -name "super_unpack_*" -o -name "ait_super_*" \) 2>/dev/null)
    if [ -n "$temp_files_list" ]; then
        local temp_bytes
        temp_bytes=$(echo "$temp_files_list" | xargs du -sb 2>/dev/null | awk '{s+=$1} END {print s}')
        total_bytes=$((total_bytes + ${temp_bytes:-0}))
    fi
    
    local total_size
    total_size=$(numfmt --to=iec-i --suffix=B --padding=7 "$total_bytes")
    
    echo -e "\n${RED}${BOLD}WARNING: IRREVERSIBLE ACTION${RESET}"
    echo -e "${YELLOW}You are about to permanently delete all files in the workspace and all related temporary files.${RESET}"
    echo -e "\n  - ${BOLD}Total space to be reclaimed: ${YELLOW}$total_size${RESET}"
    
    select_option "Are you sure you want to proceed?" "Yes, DELETE EVERYTHING" "No, take me back" --no-clear
    
    if [ "$AIT_CHOICE_INDEX" -ne 0 ]; then
        echo -e "\n${GREEN}Cleanup cancelled.${RESET}"; sleep 1; return
    fi
    
    echo -e "\n${BLUE}Cleaning workspace directories...${RESET}"
    for dir in "${dirs_to_scan[@]}"; do
        if [ -d "$dir" ]; then
            echo -e "  - Deleting contents of ${BOLD}$dir${RESET}"
            find "$dir" -mindepth 1 -not -name '.gitkeep' -delete
        fi
    done
    
    echo -e "\n${BLUE}Cleaning temporary system files...${RESET}"
    if [ -n "$temp_files_list" ]; then
        echo "$temp_files_list" | xargs sudo rm -rf
        echo -e "  - Deleted temporary files."
    else
        echo -e "  - No temporary files found."
    fi
    
    echo -e "\n${GREEN}${BOLD}[✓] Workspace and temporary files have been cleaned.${RESET}"
    read -rp $'\nPress Enter to return to the main menu...'
}

# --- Single Image Tools ---
run_unpack_interactive() {
    local input_image
    local output_dir
    local step=1
    
    while true; do
        case $step in
            1)
                # Safer item type to hide super.img
                select_item "Step 1: Select image to unpack:" "INPUT_IMAGES" "single_partition_image"
                if [ $? -ne 0 ]; then
                    return
                fi

                input_image="$AIT_SELECTED_ITEM"
                step=2
                ;;
            2)
                local default_output_dir="EXTRACTED_IMAGES/extracted_$(basename "$input_image" .img)"
                clear; print_banner; echo
                read -rp "$(echo -e ${BLUE}"Step 2: Enter output directory path [${BOLD}${default_output_dir}${BLUE}]: "${RESET})" output_dir
                output_dir=${output_dir:-$default_output_dir}
                step=3
                ;;
            3)
                clear; print_banner
                echo -e "\n${BOLD}Unpack Operation Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Output Directory:${RESET} $output_dir"
                select_option "Proceed with this operation?" "Proceed" "Back" --no-clear
                if [ "$AIT_CHOICE_INDEX" -eq 1 ]; then
                    step=1
                    continue
                fi
                
                echo -e "\n${RED}${BOLD}Starting unpack. DO NOT INTERRUPT...${RESET}\n"
                trap '' INT
                set -e; bash "$UNPACK_SCRIPT_PATH" "$input_image" "$output_dir" --no-banner; set +e
                trap 'cleanup_and_exit' INT TERM EXIT
                
                echo -e "\n${GREEN}${BOLD}Unpack successful. Files are in: $output_dir${RESET}"
                read -rp $'\nPress Enter to return...'
                break
                ;;
        esac
    done
}

run_repack_interactive() {
    local source_dir output_image fs repack_mode erofs_comp erofs_level create_sparse overhead_percent
    local step=1
    while true; do
        case $step in
            1)
                select_item "Step 1: Select directory to repack:" "EXTRACTED_IMAGES" "dir"; if [ $? -ne 0 ]; then return; fi
                source_dir="$AIT_SELECTED_ITEM"; step=2;;
            2)
                local partition_name=$(basename "$source_dir" | sed 's/^extracted_//'); local default_output_image="REPACKED_IMAGES/${partition_name}_repacked.img"; clear; print_banner; echo
                read -rp "$(echo -e ${BLUE}"Step 2: Enter output image path [${BOLD}${default_output_image}${BLUE}]: "${RESET})" output_image
                output_image=${output_image:-$default_output_image}; step=3;;
            3)
                local fs_options=("EROFS" "EXT4" "Back"); select_option "Step 3: Select filesystem:" "${fs_options[@]}";
                case $AIT_CHOICE_INDEX in 0) fs="erofs"; step=4;; 1) fs="ext4"; step=4;; 2) step=1; continue;; esac;;
            4)
                if [ "$fs" == "erofs" ]; then
                    local erofs_options=("none" "lz4" "lz4hc" "deflate" "Back"); select_option "Step 4: Select EROFS compression:" "${erofs_options[@]}"; if [ "$AIT_CHOICE_INDEX" -eq 4 ]; then step=3; continue; fi
                    erofs_comp=${erofs_options[$AIT_CHOICE_INDEX]}; erofs_level=""; if [[ "$erofs_comp" == "lz4hc" || "$erofs_comp" == "deflate" ]]; then read -rp "$(echo -e ${BLUE}"Step 4a: Level (lz4hc 0-12, deflate 0-9): "${RESET})" erofs_level; fi
                else
                    local ext4_options=("Strict (clone original)" "Flexible (auto-resize)" "Back"); select_option "Step 4: Select EXT4 repack mode:" "${ext4_options[@]}"; if [ "$AIT_CHOICE_INDEX" -eq 2 ]; then step=3; continue; fi
                    if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
                        repack_mode="strict"
                    else
                        repack_mode="flexible"
                        select_option "Select Flexible Overhead:" "Minimal (10%)" "Standard (15%)" "Generous (20%)" "Custom"
                        case $AIT_CHOICE_INDEX in
                            0) overhead_percent=10 ;;
                            2) overhead_percent=20 ;;
                            3) read -rp "$(echo -e ${BLUE}"Enter custom percentage: "${RESET})" overhead_percent ;;
                            *) overhead_percent=15 ;;
                        esac
                        overhead_percent=${overhead_percent:-15}
                    fi
                fi; step=5;;
            5)
                local sparse_options=("Yes" "No" "Back"); select_option "Step 5: Create a flashable sparse image?" "${sparse_options[@]}";
                case $AIT_CHOICE_INDEX in 0) create_sparse="true"; step=6;; 1) create_sparse="false"; step=6;; 2) step=4; continue;; esac;;
            6)
                clear; print_banner; echo -e "\n${BOLD}Repack Operation Summary:${RESET}\n  - ${YELLOW}Source Directory:${RESET} $source_dir\n  - ${YELLOW}Output Image:${RESET}     $output_image\n  - ${YELLOW}Filesystem:${RESET}       $fs"
                if [ "$fs" == "erofs" ]; then echo -e "  - ${YELLOW}EROFS Compression:${RESET}  $erofs_comp"; if [ -n "$erofs_level" ]; then echo -e "  - ${YELLOW}EROFS Level:${RESET}        ${erofs_level:-default}"; fi; else echo -e "  - ${YELLOW}EXT4 Mode:${RESET}        $repack_mode"; if [ "$repack_mode" == "flexible" ]; then echo -e "  - ${YELLOW}EXT4 Overhead:${RESET}      ${overhead_percent}%"; fi; fi
                echo -e "  - ${YELLOW}Create Sparse IMG:${RESET}  $create_sparse"; select_option "What would you like to do?" "Proceed" "Export selected settings" "Back" --no-clear;
                case $AIT_CHOICE_INDEX in 0) ;; 1) export_repack_config "$source_dir" "$output_image" "$fs" "$repack_mode" "$erofs_comp" "$erofs_level" "$create_sparse" "$overhead_percent"; step=6; continue;; 2) step=5; continue;; esac
                
                echo -e "\n${RED}${BOLD}Starting repack. DO NOT INTERRUPT...${RESET}"; trap '' INT; local repack_args=("--fs" "$fs")
                if [ "$fs" == "erofs" ]; then repack_args+=("--erofs-compression" "$erofs_comp"); if [ -n "$erofs_level" ]; then repack_args+=("--erofs-level" "$erofs_level"); fi; else repack_args+=("--ext4-mode" "$repack_mode"); if [ "$repack_mode" == "flexible" ]; then repack_args+=("--ext4-overhead-percent" "$overhead_percent"); fi; fi
                
                set -e; bash "$REPACK_SCRIPT_PATH" "$source_dir" "$output_image" "${repack_args[@]}" --no-banner; set +e; trap 'cleanup_and_exit' INT TERM EXIT; echo
                
                local final_image_path="$output_image"
                if [ -f "$output_image" ]; then
                    if [ "$create_sparse" = true ]; then
                        local sparse_output="${output_image%.img}.sparse.img"; echo -e "\n${BLUE}Converting to sparse image...${RESET}"; set -e; img2simg "$output_image" "$sparse_output"; set +e; rm -f "$output_image"; final_image_path="$sparse_output"
                    fi
                    echo -e "\n${GREEN}${BOLD}Repack successful. Final image created at: ${final_image_path}${RESET}"
                    display_final_image_size "$final_image_path"
                else echo -e "\n${RED}${BOLD}Repack failed.${RESET}"; fi
                read -rp $'\nPress Enter to return...'; break;;
        esac
    done
}

# --- Super Kitchen Functions ---
run_super_unpack_interactive() {
    local super_image session_name project_dir metadata_dir logical_dir extracted_dir

    select_item "Select super image to unpack:" "INPUT_IMAGES" "image_file"
    if [ $? -ne 0 ]; then return; fi
    super_image="$AIT_SELECTED_ITEM"

    clear; print_banner; echo
    read -rp "$(echo -e ${BLUE}"Enter a project name (no spaces): "${RESET})" session_name
    if [ -z "$session_name" ]; then
        echo -e "\n${RED}Error: Project name cannot be empty.${RESET}"; sleep 2; return
    fi

    project_dir="SUPER_TOOLS/$session_name"
    metadata_dir="$project_dir/.metadata"
    logical_dir="$project_dir/logical_partitions"
    extracted_dir="$project_dir/extracted_content"

    if [ -d "$project_dir" ]; then
        echo -e "\n${RED}Error: A project named '$session_name' already exists.${RESET}"; sleep 2; return
    fi

    mkdir -p "$project_dir" "$metadata_dir" "$logical_dir" "$extracted_dir"
    
    echo -e "\n${RED}${BOLD}Starting full super unpack. DO NOT INTERRUPT...${RESET}"
    trap '' INT
    set -e

    # Step 1: Run the initial part of super-tools to get metadata and convert to raw.
    # This is quick and the output is useful, so we show it directly.
    bash "$SUPER_SCRIPT_PATH" unpack "$super_image" "$logical_dir" --no-banner
    
    set +e # Disable exit on error for the loop
    local partition_list_file="${metadata_dir}/partition_list.txt"
    touch "$partition_list_file"
    
    local partitions_to_unpack=()
    while IFS= read -r item; do
        partitions_to_unpack+=("$item")
    done < <(find "$logical_dir" -maxdepth 1 -type f -name '*.img' ! -name 'super.raw.img' -exec basename {} .img \;)
    
    local total=${#partitions_to_unpack[@]}
    local current=0
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local all_successful=true

    echo -e "\n${BLUE}--- Extracting content from logical partitions ---${RESET}"
    for part_name in "${partitions_to_unpack[@]}"; do
        current=$((current + 1))
        local spin=0
        
        # Run the unpack in the background so we can show a spinner
        # We redirect output to /dev/null because we only care about success or failure.
        bash "$UNPACK_SCRIPT_PATH" "${logical_dir}/${part_name}.img" "${extracted_dir}/${part_name}" --no-banner >/dev/null 2>&1 &
        local pid=$!

        while kill -0 $pid 2>/dev/null; do
            echo -ne "\r\033[K${YELLOW}(${current}/${total}) Extracting: ${BOLD}${part_name}${RESET}... ${spinner[$((spin++ % 10))]}"
            sleep 0.1
        done

        wait $pid
        if [ $? -ne 0 ]; then
            echo -e "\r\033[K${RED}(${current}/${total}) FAILED to extract: ${BOLD}${part_name}${RESET} [✗]"
            all_successful=false
            break
        else
            echo -e "\r\033[K${GREEN}(${current}/${total}) Extracted: ${BOLD}${part_name}${RESET} [✓]"
            echo "$part_name" >> "$partition_list_file"
        fi
    done
    
    if [ "$all_successful" = false ]; then
        trap 'cleanup_and_exit' INT TERM EXIT
        read -rp $'\nPress Enter to return...'
        return
    fi
    
    local logical_size
    logical_size=$(du -sh "$logical_dir" | awk '{print $1}')
    echo -e "\n${BLUE}The intermediate logical partitions (${logical_size}) can be removed to save space.${RESET}"
    select_option "Delete intermediate logical partitions?" "Yes (Recommended)" "No (Keep for reference)" --no-clear

    if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
        rm -rf "$logical_dir"
        echo -e "\n${GREEN}[✓] Intermediate files removed.${RESET}"
    fi

    trap 'cleanup_and_exit' INT TERM EXIT
    echo -e "\n${GREEN}${BOLD}Super unpack successful!${RESET}"
    echo -e "  - Project created at: ${BOLD}${project_dir}${RESET}"
    echo -e "  - Extracted Partitions: ${BOLD}${total}${RESET} (${partitions_to_unpack[*]})"
    read -rp $'\nPress Enter to return...'
}

# --- MODIFIED: run_super_create_config_interactive now handles percentage overhead ---
run_super_create_config_interactive() {

    local project_dir metadata_dir final_config_file

    select_item "Select project to finalize configuration:" "SUPER_TOOLS" "dir"
    if [ $? -ne 0 ]; then return; fi
    project_dir="$AIT_SELECTED_ITEM"
    
    metadata_dir="${project_dir}/.metadata"
    final_config_file="${project_dir}/project.conf"

    if [ ! -f "${metadata_dir}/partition_list.txt" ] || [ ! -f "${metadata_dir}/super_repack_info.txt" ]; then
        echo -e "\n${RED}Error: Core metadata is missing for this project. Cannot configure.${RESET}"; sleep 2; return
    fi
    
    local partition_list
    readarray -t partition_list < "${metadata_dir}/partition_list.txt"
    
    declare -A config_lines
    
    local current_index=0
    while [ "$current_index" -lt "${#partition_list[@]}" ]; do
        local part_name=${partition_list[$current_index]}
        
        clear; print_banner
        echo -e "\n${BOLD}Configuring partition ($((current_index + 1))/${#partition_list[@]}): [ ${YELLOW}$part_name${BOLD} ]${RESET}"
        
        local menu_options=("EROFS" "EXT4")
        if [ "$current_index" -gt 0 ]; then menu_options+=("Back to previous partition"); fi
        select_option "Select filesystem for '${part_name}':" "${menu_options[@]}"
        
        if [ "$current_index" -gt 0 ] && [ "$AIT_CHOICE_INDEX" -eq 2 ]; then
            current_index=$((current_index - 1))
            continue
        fi
        
        local fs
        [ "$AIT_CHOICE_INDEX" -eq 0 ] && fs="erofs" || fs="ext4"
        config_lines["${part_name^^}_FS"]="$fs"

        unset "config_lines[${part_name^^}_EROFS_COMPRESSION]" "config_lines[${part_name^^}_EROFS_LEVEL]" "config_lines[${part_name^^}_EXT4_MODE]" "config_lines[${part_name^^}_EXT4_OVERHEAD_TYPE]" "config_lines[${part_name^^}_EXT4_OVERHEAD_VAL]"

        while true; do
            clear; print_banner
            echo -e "\n${BOLD}Configuring partition ($((current_index + 1))/${#partition_list[@]}): [ ${YELLOW}$part_name${BOLD} ]${RESET}"
            echo -e "  - Filesystem: ${GREEN}${fs}${RESET}"

            if [ "$fs" == "erofs" ]; then
                select_option "Select EROFS compression:" "none" "lz4" "lz4hc" "deflate" "Back"
                if [ "$AIT_CHOICE_INDEX" -eq 4 ]; then break; fi
                local erofs_comp_options=("none" "lz4" "lz4hc" "deflate")
                local erofs_comp=${erofs_comp_options[$AIT_CHOICE_INDEX]}
                config_lines["${part_name^^}_EROFS_COMPRESSION"]="$erofs_comp"
                if [[ "$erofs_comp" == "lz4hc" || "$erofs_comp" == "deflate" ]]; then
                    read -rp "$(echo -e ${BLUE}"Enter level for ${erofs_comp} (lz4hc 0-12, deflate 0-9): "${RESET})" erofs_level
                    config_lines["${part_name^^}_EROFS_LEVEL"]="$erofs_level"
                fi
                current_index=$((current_index + 1)); break

            else # EXT4
                select_option "Select EXT4 repack mode:" "Flexible (auto-resize)" "Strict" "Back"
                if [ "$AIT_CHOICE_INDEX" -eq 2 ]; then break; fi
                local ext4_mode
                if [ "$AIT_CHOICE_INDEX" -eq 0 ]; then
                    ext4_mode="flexible"
                    config_lines["${part_name^^}_EXT4_MODE"]="$ext4_mode"
                    select_option "Select Flexible Overhead:" "Minimal (10%)" "Standard (15%)" "Generous (20%)" "Custom"
                    local overhead_percent
                    case $AIT_CHOICE_INDEX in
                        0) overhead_percent=10 ;;
                        2) overhead_percent=20 ;;
                        3) read -rp "$(echo -e ${BLUE}"Enter custom percentage: "${RESET})" overhead_percent ;;
                        *) overhead_percent=15 ;;
                    esac
                    config_lines["${part_name^^}_EXT4_OVERHEAD_PERCENT"]="${overhead_percent:-15}"
                else
                    ext4_mode="strict"
                    config_lines["${part_name^^}_EXT4_MODE"]="$ext4_mode"
                fi
                current_index=$((current_index + 1)); break
            fi
        done
    done
    
    {
        echo "# --- Universal Repack Configuration ---"
        echo "# Project: $(basename "$project_dir")"
        echo "# Generated on $(date)"
        echo "# WARNING: Do NOT edit this file manually unless you know what you are doing."
        echo ""
        echo "# --- Super Partition Metadata ---"
        grep -v -E '^(#|$)' "${metadata_dir}/super_repack_info.txt"
        echo ""
        echo "# --- Logical Partition Repack Settings ---"
        echo "PARTITION_LIST=\"${partition_list[*]}\""
        echo ""

    for part_name in "${partition_list[@]}"; do
        echo "# Settings for ${part_name}"
        echo "${part_name^^}_FS=\"${config_lines[${part_name^^}_FS]}\""
        if [ "${config_lines[${part_name^^}_FS]}" == "erofs" ]; then
            echo "${part_name^^}_EROFS_COMPRESSION=\"${config_lines[${part_name^^}_EROFS_COMPRESSION]}\""
            if [ -n "${config_lines[${part_name^^}_EROFS_LEVEL]}" ]; then echo "${part_name^^}_EROFS_LEVEL=\"${config_lines[${part_name^^}_EROFS_LEVEL]}\""; fi
        else
            echo "${part_name^^}_EXT4_MODE=\"${config_lines[${part_name^^}_EXT4_MODE]}\""
            if [ "${config_lines[${part_name^^}_EXT4_MODE]}" == "flexible" ]; then
                echo "${part_name^^}_EXT4_OVERHEAD_PERCENT=\"${config_lines[${part_name^^}_EXT4_OVERHEAD_PERCENT]}\""
            fi
        fi
        echo ""
    done
    } > "$final_config_file"

    echo -e "\n${GREEN}${BOLD}[✓] Universal repack configuration saved to:${RESET}\n${final_config_file}"
    read -rp $'\nPress Enter to return...'
}

# --- MODIFIED: run_super_repack_interactive now passes percentage overhead ---
run_super_repack_interactive() {

    local project_dir metadata_dir part_config_file logical_dir extracted_dir

    select_item "Select project to repack:" "SUPER_TOOLS" "dir"
    if [ $? -ne 0 ]; then return; fi
    project_dir="$AIT_SELECTED_ITEM"
    
    metadata_dir="${project_dir}/.metadata"
    logical_dir="${project_dir}/logical_partitions"
    extracted_dir="${project_dir}/extracted_content"
    part_config_file="${project_dir}/project.conf"

    if [ ! -f "$part_config_file" ]; then
        echo -e "\n${RED}Error: Universal 'project.conf' not found!${RESET}"
        echo -e "Please run 'Finalize Project Configuration' for this project first."
        sleep 3; return
    fi
    
    source "$part_config_file"
    
    clear; print_banner
    local default_output_image="REPACKED_IMAGES/super_$(basename "$project_dir").img"
    read -rp "$(echo -e ${BLUE}"Enter path for final super image [${BOLD}${default_output_image}${BLUE}]: "${RESET})" output_image
    output_image=${output_image:-$default_output_image}
    
    select_option "Create a flashable sparse image?" "Yes (Recommended)" "No (Raw Image)"
    local sparse_flag=""
    [ "$AIT_CHOICE_INDEX" -eq 1 ] && sparse_flag="--raw"

    echo -e "\n${RED}${BOLD}Starting full super repack. This will take a long time...${RESET}"
    trap '' INT
    set -e
    
    mkdir -p "$logical_dir"
    
    set +e # Disable exit on error for the loop
    local total=$(echo "$PARTITION_LIST" | wc -w)
    local current=0
    local spinner=( '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏' )
    local all_successful=true

    echo -e "\n${BLUE}--- Repacking content into logical partitions ---${RESET}"

    for part_name in $PARTITION_LIST; do
        current=$((current + 1))
        local fs_var="${part_name^^}_FS"; local fs="${!fs_var}"
        local repack_args=("--fs" "$fs")
        if [ "$fs" == "erofs" ]; then
            local comp_var="${part_name^^}_EROFS_COMPRESSION"; local level_var="${part_name^^}_EROFS_LEVEL"
            [ -n "${!comp_var}" ] && repack_args+=("--erofs-compression" "${!comp_var}")
            [ -n "${!level_var}" ] && repack_args+=("--erofs-level" "${!level_var}")
        else
            local mode_var="${part_name^^}_EXT4_MODE"; [ -n "${!mode_var}" ] && repack_args+=("--ext4-mode" "${!mode_var}")
            if [ "${!mode_var}" == "flexible" ]; then
                local percent_var="${part_name^^}_EXT4_OVERHEAD_PERCENT"
                repack_args+=("--ext4-overhead-percent" "${!percent_var}")
            fi
        fi
        
        bash "$REPACK_SCRIPT_PATH" "${project_dir}/extracted_content/${part_name}" "${logical_dir}/${part_name}.img" "${repack_args[@]}" --no-banner >/dev/null 2>&1 &
        local pid=$!

        while kill -0 $pid 2>/dev/null; do
            echo -ne "\r\033[K${YELLOW}(${current}/${total}) Repacking: ${BOLD}${part_name}${RESET}... ${spinner[$((spin++ % 10))]}"
            sleep 0.1
        done

        wait $pid
        if [ $? -ne 0 ]; then
            echo -e "\r\033[K${RED}(${current}/${total}) FAILED to repack: ${BOLD}${part_name}${RESET} [✗]"
            all_successful=false
            break
        else
            echo -e "\r\033[K${GREEN}(${current}/${total}) Repacked:  ${BOLD}${part_name}${RESET} [✓]"
        fi

    done

    if [ "$all_successful" = false ]; then
        trap 'cleanup_and_exit' INT TERM EXIT
        read -rp $'\nPress Enter to return...'
        return
    fi
    
    echo -e "\n${BLUE}--- Assembling final super image ---${RESET}"
    bash "$SUPER_SCRIPT_PATH" repack "$logical_dir" "$output_image" "$sparse_flag" --no-banner
    
    rm -rf "$logical_dir"
    set +e
    trap 'cleanup_and_exit' INT TERM EXIT
    
    echo -e "\n${GREEN}${BOLD}Super repack successful!${RESET}"
    echo -e "  - Final image: ${BOLD}$output_image${RESET}"
    display_final_image_size "$output_image"
    read -rp $'\nPress Enter to return...'
}

run_super_kitchen_menu() {
    while true; do
        clear; print_banner
        local kitchen_options=("Unpack a Super Image" "Finalize Project Configuration" "Repack a Project from Configuration" "Back to Main Menu")
        select_option "Super Image Kitchen:" "${kitchen_options[@]}"
        
        case $AIT_CHOICE_INDEX in
            0) run_super_unpack_interactive ;;
            1) run_super_create_config_interactive ;;
            2) run_super_repack_interactive ;;
            3) break ;;
        esac
    done
}

run_advanced_tools_menu() {
    while true; do
        clear; print_banner
        local advanced_options=("Super Image Kitchen" "Back to Main Menu")
        select_option "Advanced Tools:" "${advanced_options[@]}"
        
        case $AIT_CHOICE_INDEX in
            0) run_super_kitchen_menu ;;
            1) break ;;
        esac
    done
}

# --- MODIFIED: run_non_interactive now handles percentage overhead ---
run_non_interactive() {
    set -e
    local config_file="$1"
    echo -e "\n${BLUE}Running non-interactive with: ${BOLD}$config_file${RESET}"
    declare -A CONFIG
    while IFS='=' read -r key value; do if [[ ! "$key" =~ ^\# && -n "$key" ]]; then CONFIG["$key"]="$value"; fi; done < "$config_file"
    ACTION="${CONFIG[ACTION]}"
    if [ -z "$ACTION" ]; then echo -e "${RED}Error: 'ACTION' not defined.${RESET}"; exit 1; fi
    trap '' INT

    if [ "$ACTION" == "unpack" ]; then
        local input_image="${CONFIG[INPUT_IMAGE]}"; local extract_dir="${CONFIG[EXTRACT_DIR]}"
        if [[ "$input_image" != /* ]]; then input_image="INPUT_IMAGES/$input_image"; fi
        if [[ "$extract_dir" != /* ]]; then extract_dir="EXTRACTED_IMAGES/$extract_dir"; fi
        if [ -z "$input_image" ] || [ -z "$extract_dir" ]; then echo -e "${RED}Error: INPUT_IMAGE/EXTRACT_DIR not set.${RESET}"; exit 1; fi
        
        echo -e "\n${BOLD}Unpack Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Output Directory:${RESET} $extract_dir"
        echo -e "\n${RED}${BOLD}Starting unpack. DO NOT INTERRUPT...${RESET}\n"; bash "$UNPACK_SCRIPT_PATH" "$input_image" "$extract_dir" --no-banner
        echo -e "\n${GREEN}${BOLD}Success: Image unpacked to $extract_dir${RESET}"

    elif [ "$ACTION" == "repack" ]; then
        local source_dir="${CONFIG[SOURCE_DIR]}"; local output_image="${CONFIG[OUTPUT_IMAGE]}"; local fs="${CONFIG[FILESYSTEM]}"
        if [[ "$source_dir" != /* ]]; then source_dir="EXTRACTED_IMAGES/$source_dir"; fi
        if [[ "$output_image" != /* ]]; then output_image="REPACKED_IMAGES/$output_image"; fi
        if [ -z "$source_dir" ] || [ -z "$output_image" ] || [ -z "$fs" ]; then echo -e "${RED}Error: SOURCE_DIR/OUTPUT_IMAGE/FILESYSTEM not set.${RESET}"; exit 1; fi
        
        local repack_args=("--fs" "$fs"); local create_sparse="${CONFIG[CREATE_SPARSE_IMAGE]:-true}"; local erofs_comp="${CONFIG[COMPRESSION_MODE]}"; local erofs_level="${CONFIG[COMPRESSION_LEVEL]}"; local ext4_mode="${CONFIG[MODE]}"
        
        echo -e "\n${BOLD}Repack Summary:${RESET}\n  - ${YELLOW}Source Directory:${RESET} $source_dir\n  - ${YELLOW}Output Image:${RESET}     $output_image\n  - ${YELLOW}Filesystem:${RESET}       $fs"
        if [ "$fs" == "erofs" ]; then
            [ -n "$erofs_comp" ] && repack_args+=("--erofs-compression" "$erofs_comp"); [ -n "$erofs_level" ] && repack_args+=("--erofs-level" "$erofs_level")
            echo -e "  - ${YELLOW}EROFS Compression:${RESET}  ${erofs_comp:-none}"
        else
            [ -n "$ext4_mode" ] && repack_args+=("--ext4-mode" "$ext4_mode")
            echo -e "  - ${YELLOW}EXT4 Mode:${RESET}        ${ext4_mode:-strict}"
            if [ "$ext4_mode" == "flexible" ]; then
                local overhead_percent="${CONFIG[EXT4_OVERHEAD_PERCENT]:-5}"
                repack_args+=("--ext4-overhead-percent" "$overhead_percent")
                echo -e "  - ${YELLOW}EXT4 Overhead:${RESET}      ${overhead_percent}%"
            fi
        fi
        echo -e "  - ${YELLOW}Create Sparse IMG:${RESET}  $create_sparse"
        
        echo -e "\n${RED}${BOLD}Starting repack. DO NOT INTERRUPT...${RESET}"; bash "$REPACK_SCRIPT_PATH" "$source_dir" "$output_image" "${repack_args[@]}" --no-banner

        local final_image_path="$output_image"
        if [ -f "$output_image" ]; then
            if [ "$create_sparse" == "true" ]; then
                local sparse_output="${output_image%.img}.sparse.img"; echo -e "\n${BLUE}Creating sparse image...${RESET}"; img2simg "$output_image" "$sparse_output"; rm -f "$output_image"; final_image_path="$sparse_output"
            fi
            echo -e "\n${GREEN}${BOLD}Success: Final image created at: ${final_image_path}${RESET}"
            display_final_image_size "$final_image_path"
        else
            echo -e "\n${RED}${BOLD}Repack failed.${RESET}"
        fi
        
    # --- NEW: Non-interactive super unpack ---
    elif [ "$ACTION" == "super_unpack" ]; then
        local input_image="${CONFIG[INPUT_IMAGE]}"
        local project_name="${CONFIG[PROJECT_NAME]}"
        if [[ "$input_image" != /* ]]; then input_image="INPUT_IMAGES/$input_image"; fi
        if [ -z "$input_image" ] || [ -z "$project_name" ]; then echo -e "${RED}Error: INPUT_IMAGE/PROJECT_NAME not set.${RESET}"; exit 1; fi
        
        local project_dir="SUPER_TOOLS/$project_name"
        if [ -d "$project_dir" ]; then echo -e "${RED}Error: Project '$project_name' already exists.${RESET}"; exit 1; fi

        echo -e "\n${BOLD}Super Unpack Summary:${RESET}\n  - ${YELLOW}Input Image:${RESET} $input_image\n  - ${YELLOW}Project Name:${RESET} $project_name"
        echo -e "\n${RED}${BOLD}Starting super unpack...${RESET}"

        # Mirror the interactive logic        
        mkdir -p "$project_dir/.metadata" "$project_dir/logical_partitions" "$project_dir/extracted_content"
        bash "$SUPER_SCRIPT_PATH" unpack "$input_image" "$project_dir/logical_partitions" --no-banner &>/dev/null
        
        find "$project_dir/logical_partitions" -maxdepth 1 -type f -name '*.img' ! -name 'super.raw.img' | while read -r logical_img; do
            local part_name
            part_name=$(basename "$logical_img" .img)
            echo -e "--- Unpacking logical partition: ${part_name} ---"
            bash "$UNPACK_SCRIPT_PATH" "$logical_img" "$project_dir/extracted_content/${part_name}" --no-banner &>/dev/null
        done
        rm -rf "$project_dir/logical_partitions"
        echo -e "\n${GREEN}${BOLD}Success: Super image unpacked to $project_dir${RESET}"

    # --- Non-interactive super repack ---
    elif [ "$ACTION" == "super_repack" ]; then
        local project_name="${CONFIG[PROJECT_NAME]}"; local output_image="${CONFIG[OUTPUT_IMAGE]}"
        if [[ "$output_image" != /* ]]; then output_image="REPACKED_IMAGES/$output_image"; fi
        if [ -z "$project_name" ] || [ -z "$output_image" ]; then echo -e "${RED}Error: PROJECT_NAME/OUTPUT_IMAGE not set.${RESET}"; exit 1; fi
        local project_dir="SUPER_TOOLS/$project_name"; local final_config_file="${project_dir}/project.conf"
        if [ ! -f "$final_config_file" ]; then echo -e "${RED}Error: 'project.conf' not found in '$project_dir'.${RESET}"; exit 1; fi
        
        source "$final_config_file"
        echo -e "\n${BOLD}Super Repack Summary:${RESET}\n  - ${YELLOW}Project:${RESET} $project_name\n  - ${YELLOW}Output Image:${RESET} $output_image"
        echo -e "\n${RED}${BOLD}Starting super repack...${RESET}"
        
        local logical_dir="${project_dir}/logical_partitions"; mkdir -p "$logical_dir"
        
        for part_name in $PARTITION_LIST; do
            echo "--- Repacking logical partition: ${part_name} ---"
            local fs_var="${part_name^^}_FS"; local fs="${!fs_var}"
            local repack_args=("--fs" "$fs")
            if [ "$fs" == "erofs" ]; then
                local comp_var="${part_name^^}_EROFS_COMPRESSION"; local level_var="${part_name^^}_EROFS_LEVEL"
                [ -n "${!comp_var}" ] && repack_args+=("--erofs-compression" "${!comp_var}"); [ -n "${!level_var}" ] && repack_args+=("--erofs-level" "${!level_var}")
            else
                local mode_var="${part_name^^}_EXT4_MODE"; [ -n "${!mode_var}" ] && repack_args+=("--ext4-mode" "${!mode_var}")
                if [ "${!mode_var}" == "flexible" ]; then
                    local percent_var="${part_name^^}_EXT4_OVERHEAD_PERCENT"
                    repack_args+=("--ext4-overhead-percent" "${!percent_var}")
                fi
            fi
            bash "$REPACK_SCRIPT_PATH" "$project_dir/extracted_content/${part_name}" "$logical_dir/${part_name}.img" "${repack_args[@]}" --no-banner &>/dev/null
        done

        echo "--- Assembling final super image ---"
        local sparse_flag=""; [ "${CONFIG[CREATE_SPARSE_IMAGE]}" == "false" ] && sparse_flag="--raw"
        bash "$SUPER_SCRIPT_PATH" repack "$logical_dir" "$output_image" "$sparse_flag" --no-banner &>/dev/null
        rm -rf "$logical_dir"
        
        echo -e "\n${GREEN}${BOLD}Success: Final image created at: ${output_image}${RESET}"
        display_final_image_size "$output_image"
    else
        echo -e "${RED}Error: Invalid ACTION '${ACTION}'.${RESET}"; exit 1
    fi
    trap 'cleanup_and_exit' INT TERM EXIT
}

# --- Main Execution Logic ---
check_distro
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script requires root privileges. Please run with sudo.${RESET}"; exit 1
fi

if [ "$#" -gt 1 ] || { [ -n "$1" ] && [[ "$1" != "--conf="* ]]; }; then
    print_usage "$1"
fi

# Handle the valid non-interactive case
if [[ "$1" == "--conf="* ]]; then
    conf_file="${1#*=}"
    if [ ! -f "$conf_file" ]; then
        echo -e "${RED}Error: Config file not found: '$conf_file'${RESET}"; exit 1
    fi
    print_banner
    check_dependencies
    create_workspace
    run_non_interactive "$conf_file"
    exit 0
fi

set +e
while true; do
    clear; print_banner
    if [ -z "$WORKSPACE_INITIALIZED" ]; then
        check_dependencies
        create_workspace
        WORKSPACE_INITIALIZED=true
    fi
    
    # Main Menu Reordered
    main_options=("Unpack an Android Image" "Repack a Directory" "Generate default.conf file" "Advanced Tools" "Cleanup Workspace" "Exit")
    select_option "Select an action:" "${main_options[@]}"; choice=$AIT_CHOICE_INDEX
    
    case $choice in
        0) run_unpack_interactive;;
        1) run_repack_interactive;;
        2) generate_config_file; read -rp $'\nPress Enter to continue...';;
        3) run_advanced_tools_menu;;
        4) cleanup_workspace;;
        5) break;;
    esac

done
