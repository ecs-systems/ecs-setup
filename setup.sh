#!/bin/bash
# ============================================
# ECS-Studio — Create New Project
# ============================================
#
# Usage: setup.sh [OPTIONS]
#
# Options:
#   -p, --project NAME    Project name (default: MyBook)
#   -a, --author NAME     Author name (required for new projects)
#   -m, --module ID       Module ID (e.g., ecs-writer, ecs-marketing)
#   -l, --language LANG   Language code (e.g., en, de)
#   -y, --yes             Auto-confirm all prompts (non-interactive)
#   -u, --update          Update setup.sh to the latest version
#   -v, --version         Show current version
#   --no-update-check     Skip automatic update check
#   -h, --help            Show this help message
#
# Examples:
#   ./setup.sh                                              # Interactive mode
#   ./setup.sh -m ecs-writer -l en -p MyNovel -a "John" -y  # Fully automated
#   ./setup.sh --module ecs-marketing --project Launch      # Partial automation
#   ./setup.sh --update                                     # Update to latest version
#
# Modules and languages are auto-detected from the ecs-studio repository.
#
# ============================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Version and Update Settings
SETUP_VERSION="1.0.0"
SETUP_REPO="ecs-systems/ecs-setup"
SETUP_SCRIPT_URL="https://raw.githubusercontent.com/ecs-systems/ecs-setup/main/setup.sh"
UPDATE_CHECK_INTERVAL=86400  # 24 hours in seconds

ECS_HOME="$HOME/ECS-Studio"
TOOLS_DIR="$ECS_HOME/.tools"
CACHE_DIR="$ECS_HOME/.cache"
CACHE_AUTHOR="$CACHE_DIR/author_name"
CACHE_MODULE="$CACHE_DIR/module"
CACHE_LANGUAGE="$CACHE_DIR/language"
CACHE_UPDATE_CHECK="$CACHE_DIR/update_check"

# Find gh binary: local installation first, then system-wide
find_gh_binary() {
    local local_gh="$TOOLS_DIR/gh/bin/gh"
    if [ -x "$local_gh" ]; then
        echo "$local_gh"
    elif command -v gh &> /dev/null; then
        command -v gh
    else
        echo ""
    fi
}

GH_BIN=$(find_gh_binary)

# Command line parameters (empty = not set)
ARG_PROJECT=""
ARG_AUTHOR=""
ARG_MODULE=""
ARG_LANGUAGE=""
ARG_YES=false
ARG_UPDATE=false
ARG_VERSION=false
ARG_NO_UPDATE_CHECK=false

# Runtime variables
SELECTED_MODULE=""
SELECTED_LANGUAGE=""
PROJECT_NAME=""
AUTHOR_NAME=""
MODULE_DIR=""  # Temporary directory with cloned modules
CUSTOM_MODULE=false  # Flag for custom module from user's repos
CUSTOM_REPO=""  # Selected custom repository name
CUSTOM_REPO_DIR=""  # Temporary directory for custom repo

# ============================================
# Argument Parsing
# ============================================

show_help() {
    echo "ECS-Studio — Create New Project"
    echo ""
    echo "Usage: setup.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -p, --project NAME    Project name (default: MyBook)"
    echo "  -a, --author NAME     Author name (required for new projects)"
    echo "  -m, --module ID       Module ID (e.g., ecs-writer, ecs-marketing)"
    echo "  -l, --language LANG   Language code (e.g., en, de)"
    echo "  -y, --yes             Auto-confirm all prompts (non-interactive)"
    echo "  -u, --update          Update setup.sh to the latest version"
    echo "  -v, --version         Show current version"
    echo "  --no-update-check     Skip automatic update check"
    echo "  -h, --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./setup.sh                                              # Interactive mode"
    echo "  ./setup.sh -m ecs-writer -l en -p MyNovel -a \"John\" -y  # Fully automated"
    echo "  ./setup.sh --module ecs-marketing --project Launch      # Partial automation"
    echo "  ./setup.sh --update                                     # Update to latest version"
    echo ""
    echo "Modules and languages are auto-detected from the repository."
    echo ""
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -p|--project)
                ARG_PROJECT="$2"
                shift 2
                ;;
            -a|--author)
                ARG_AUTHOR="$2"
                shift 2
                ;;
            -m|--module)
                ARG_MODULE="$2"
                shift 2
                ;;
            -l|--language)
                ARG_LANGUAGE="$2"
                shift 2
                ;;
            -y|--yes)
                ARG_YES=true
                shift
                ;;
            -u|--update)
                ARG_UPDATE=true
                shift
                ;;
            -v|--version)
                ARG_VERSION=true
                shift
                ;;
            --no-update-check)
                ARG_NO_UPDATE_CHECK=true
                shift
                ;;
            -h|--help|-\?)
                show_help
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information."
                exit 1
                ;;
        esac
    done
}

# ============================================
# YAML Helper Functions (simple, no yq needed)
# ============================================

# Get a simple YAML value (single line, no nested)
get_yaml_value() {
    local file="$1"
    local key="$2"
    grep "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*: *//' | tr -d '"' | tr -d "'"
}

# Get YAML array values (simple format: - "value")
get_yaml_array() {
    local file="$1"
    local key="$2"
    local in_section=false

    while IFS= read -r line; do
        # Check if we're entering the section
        if [[ "$line" =~ ^${key}: ]]; then
            in_section=true
            continue
        fi

        # Check if we're leaving the section (new key at root level)
        if $in_section && [[ "$line" =~ ^[a-z_]+: ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            break
        fi

        # If in section, extract array values
        if $in_section && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.*) ]]; then
            local value="${BASH_REMATCH[1]}"
            # Remove quotes
            value=$(echo "$value" | tr -d '"' | tr -d "'")
            echo "$value"
        fi
    done < "$file"
}

# Get YAML multiline value (key: |)
get_yaml_multiline() {
    local file="$1"
    local key="$2"
    local in_section=false
    local indent=""

    while IFS= read -r line; do
        # Check if we're entering the section
        if [[ "$line" =~ ^${key}:[[:space:]]*\|[[:space:]]*$ ]]; then
            in_section=true
            continue
        fi

        # If in section
        if $in_section; then
            # Check if this is the first content line (to get indent)
            if [ -z "$indent" ] && [[ "$line" =~ ^([[:space:]]+) ]]; then
                indent="${BASH_REMATCH[1]}"
            fi

            # Check if we're leaving the section (line with less or no indent that's not empty)
            if [ -n "$indent" ] && [[ ! "$line" =~ ^${indent} ]] && [[ -n "$line" ]] && [[ ! "$line" =~ ^[[:space:]]*$ ]]; then
                break
            fi

            # Output the line (remove the base indent)
            if [ -n "$indent" ]; then
                echo "${line#$indent}"
            else
                echo "$line"
            fi
        fi
    done < "$file"
}

# Detect available modules from repository root
detect_available_modules() {
    local repo_dir="$1"

    for module_dir in "$repo_dir"/*/; do
        [ -d "$module_dir" ] || continue
        if [ -f "$module_dir/module.yaml" ]; then
            basename "$module_dir"
        fi
    done
}

# Detect available languages for a specific module
detect_available_languages() {
    local module_path="$1"

    for lang_dir in "$module_path"/*/; do
        [ -d "$lang_dir" ] || continue
        if [ -f "$lang_dir/language.yaml" ]; then
            basename "$lang_dir"
        fi
    done
}

# Check if a language alias matches for a specific module
match_language_alias() {
    local module_path="$1"
    local input="$2"

    for lang_dir in "$module_path"/*/; do
        [ -d "$lang_dir" ] || continue
        local yaml_file="$lang_dir/language.yaml"
        [ -f "$yaml_file" ] || continue

        local code=$(get_yaml_value "$yaml_file" "code")

        # Check direct code match
        if [ "$input" = "$code" ]; then
            echo "$code"
            return 0
        fi

        # Check aliases
        while IFS= read -r alias; do
            if [ "$input" = "$alias" ]; then
                echo "$code"
                return 0
            fi
        done < <(get_yaml_array "$yaml_file" "aliases")
    done

    return 1
}

# Plattform erkennen (Linux, macOS, WSL)
detect_platform() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif grep -qEi "(microsoft|wsl)" /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

PLATFORM=$(detect_platform)

# Plattformunabhängiges sed -i
sed_inplace() {
    if [ "$PLATFORM" = "macos" ]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ============================================
# Hilfsfunktionen
# ============================================

print_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}ECS-Studio - New Project${NC}               ${CYAN}║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}▶${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

ask_question() {
    local prompt="$1"
    local default="$2"
    local result

    if [ -n "$default" ]; then
        echo -ne "${CYAN}?${NC} ${prompt} ${BOLD}[${default}]${NC}: " >&2
        read -r result
        echo "${result:-$default}"
    else
        echo -ne "${CYAN}?${NC} ${prompt}: " >&2
        read -r result
        echo "$result"
    fi
}

confirm() {
    local prompt="$1"

    # Auto-confirm if --yes flag is set
    if [ "$ARG_YES" = true ]; then
        echo -e "${CYAN}?${NC} ${prompt} ${BOLD}[Y/n]${NC}: y (auto)"
        return 0
    fi

    local response
    echo -ne "${CYAN}?${NC} ${prompt} ${BOLD}[Y/n]${NC}: "
    read -r response
    case "$response" in
        [nN]|[nN][oO]) return 1 ;;
        *) return 0 ;;
    esac
}

# Andere Projekte im ECS_HOME finden (außer dem aktuellen)
get_other_projects() {
    local current_project="$1"
    local projects=()

    # Alle Unterverzeichnisse in ECS_HOME durchsuchen
    for dir in "$ECS_HOME"/*/; do
        # Verzeichnisname extrahieren
        local name=$(basename "$dir")

        # Versteckte Ordner und aktuelles Projekt überspringen
        [[ "$name" == .* ]] && continue
        [[ "$name" == "$current_project" ]] && continue

        # Prüfen ob es ein ECS-Projekt ist (hat _bmad/ecs Ordner)
        if [ -d "$dir/_bmad/ecs" ]; then
            projects+=("$name")
        fi
    done

    # Projekte zurückgeben (eines pro Zeile)
    printf '%s\n' "${projects[@]}"
}

# ============================================
# Auto-Update Functions
# ============================================

# Get version from remote script
get_remote_version() {
    curl -sL "$SETUP_SCRIPT_URL" 2>/dev/null | grep "^SETUP_VERSION=" | head -1 | cut -d'"' -f2
}

# Compare versions (semantic versioning)
# Returns 0 if $1 > $2
version_gt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$1" ]
}

# Check if update check is needed (based on cache)
should_check_updates() {
    [ ! -f "$CACHE_UPDATE_CHECK" ] && return 0

    local last_check
    last_check=$(cat "$CACHE_UPDATE_CHECK" 2>/dev/null)
    [ -z "$last_check" ] && return 0

    local now diff
    now=$(date +%s)
    diff=$((now - last_check))

    [ "$diff" -gt "$UPDATE_CHECK_INTERVAL" ]
}

# Check for updates (returns new version if available)
check_for_updates() {
    if ! should_check_updates; then
        return 1  # Recently checked, skip
    fi

    local remote_version
    remote_version=$(get_remote_version)

    # Update cache timestamp
    mkdir -p "$CACHE_DIR"
    date +%s > "$CACHE_UPDATE_CHECK"

    if [ -z "$remote_version" ]; then
        return 1  # Could not check
    fi

    if version_gt "$remote_version" "$SETUP_VERSION"; then
        echo "$remote_version"
        return 0  # Update available
    fi

    return 1  # No update
}

# Perform the update
perform_update() {
    local script_path="$0"
    local backup_path="${script_path}.backup"

    print_step "Downloading latest version..."

    local new_script
    new_script=$(curl -sL "$SETUP_SCRIPT_URL")

    if [ -z "$new_script" ]; then
        print_error "Failed to download update."
        return 1
    fi

    # Verify downloaded script has a version
    local new_version
    new_version=$(echo "$new_script" | grep "^SETUP_VERSION=" | head -1 | cut -d'"' -f2)

    if [ -z "$new_version" ]; then
        print_error "Downloaded script appears invalid (no version found)."
        return 1
    fi

    # Create backup
    cp "$script_path" "$backup_path"
    print_success "Backup created: $backup_path"

    # Write new script
    echo "$new_script" > "$script_path"
    chmod +x "$script_path"

    print_success "Updated to version $new_version"

    # Update cache to avoid immediate re-check
    mkdir -p "$CACHE_DIR"
    date +%s > "$CACHE_UPDATE_CHECK"

    # Restart script with original arguments (minus --update)
    local args=()
    for arg in "$@"; do
        if [ "$arg" != "--update" ] && [ "$arg" != "-u" ]; then
            args+=("$arg")
        fi
    done

    if [ ${#args[@]} -gt 0 ]; then
        exec "$script_path" "${args[@]}"
    else
        exec "$script_path"
    fi
}

# ============================================
# Module Loading
# ============================================

load_modules() {
    print_step "Loading available modules..."

    MODULE_DIR=$(mktemp -d)

    # Clone the module repository
    local clone_output
    if ! clone_output=$("$GH_BIN" repo clone ecs-systems/ecs-studio "$MODULE_DIR" -- --depth 1 2>&1); then
        print_error "Failed to load modules."
        echo ""
        echo "Error details:"
        echo "$clone_output" | head -5
        echo ""
        echo "Possible causes:"
        echo "  - No internet connection"
        echo "  - GitHub authentication expired"
        echo "  - No access to the repository"
        echo ""
        echo "Try running:"
        echo "  $GH_BIN auth status"
        echo "  $GH_BIN auth login"
        echo ""
        rm -rf "$MODULE_DIR"
        exit 1
    fi

    # Count available modules
    local module_count=0
    for mod in $(detect_available_modules "$MODULE_DIR"); do
        module_count=$((module_count + 1))
    done

    if [ "$module_count" -eq 0 ]; then
        print_error "No modules found in repository."
        rm -rf "$MODULE_DIR"
        exit 1
    fi

    print_success "Found $module_count module(s)"
}

cleanup_modules() {
    if [ -n "$MODULE_DIR" ] && [ -d "$MODULE_DIR" ]; then
        rm -rf "$MODULE_DIR"
    fi
    if [ -n "$CUSTOM_REPO_DIR" ] && [ -d "$CUSTOM_REPO_DIR" ]; then
        rm -rf "$CUSTOM_REPO_DIR"
    fi
}

# ============================================
# Custom Module from User's Repositories
# ============================================

# List user's repositories
list_user_repos() {
    "$GH_BIN" repo list --limit 100 --json name,description,updatedAt \
        --jq '.[] | "\(.name)\t\(.description // "No description")"' 2>/dev/null
}

# Choose a custom module from user's repositories
choose_custom_module() {
    print_step "Loading your repositories..."

    local repos=()
    local repo_descriptions=()

    while IFS=$'\t' read -r name desc; do
        [ -z "$name" ] && continue
        repos+=("$name")
        repo_descriptions+=("$desc")
    done < <(list_user_repos)

    if [ "${#repos[@]}" -eq 0 ]; then
        print_error "No repositories found in your GitHub account."
        return 1
    fi

    print_success "Found ${#repos[@]} repository/repositories"

    echo ""
    echo -e "${BOLD}Choose a repository as template:${NC}"
    echo ""

    # Show repos with pagination (first 20)
    local show_count=20
    local i=1
    for idx in "${!repos[@]}"; do
        if [ "$i" -gt "$show_count" ]; then
            echo "  ... and $((${#repos[@]} - show_count)) more (enter name to search)"
            break
        fi
        local desc="${repo_descriptions[$idx]}"
        if [ ${#desc} -gt 50 ]; then
            desc="${desc:0:47}..."
        fi
        printf "  %2d) %-25s %s\n" "$i" "${repos[$idx]}" "$desc"
        i=$((i + 1))
    done
    echo ""

    local choice
    choice=$(ask_question "Repository (number or name)" "1")

    # Handle numeric choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#repos[@]}" ]; then
        CUSTOM_REPO="${repos[$((choice-1))]}"
    else
        # Try to match as name (partial match)
        local found=false
        for repo in "${repos[@]}"; do
            if [[ "$repo" == *"$choice"* ]]; then
                CUSTOM_REPO="$repo"
                found=true
                break
            fi
        done

        if ! $found; then
            print_error "Repository not found: $choice"
            return 1
        fi
    fi

    print_success "Selected: $CUSTOM_REPO"

    # Clone the custom repository
    print_step "Loading repository '$CUSTOM_REPO'..."

    CUSTOM_REPO_DIR=$(mktemp -d)

    local clone_output
    if ! clone_output=$("$GH_BIN" repo clone "$GH_USER/$CUSTOM_REPO" "$CUSTOM_REPO_DIR" -- --depth 1 2>&1); then
        print_error "Failed to clone repository."
        echo "$clone_output" | head -3
        rm -rf "$CUSTOM_REPO_DIR"
        return 1
    fi

    print_success "Repository loaded"

    # Set flags
    CUSTOM_MODULE=true
    SELECTED_MODULE="custom"

    return 0
}

# ============================================
# Module Selection (before language)
# ============================================

choose_module() {
    # Get available modules
    local modules=()
    local module_names=()
    local module_taglines=()

    for mod in $(detect_available_modules "$MODULE_DIR"); do
        modules+=("$mod")
        local yaml_file="$MODULE_DIR/$mod/module.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        local tagline=$(get_yaml_value "$yaml_file" "tagline")
        module_names+=("$name")
        module_taglines+=("$tagline")
    done

    # If only one module, use it automatically
    if [ "${#modules[@]}" -eq 1 ]; then
        SELECTED_MODULE="${modules[0]}"
        local yaml_file="$MODULE_DIR/$SELECTED_MODULE/module.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        print_success "Module: $name (only one available)"
        return
    fi

    # If module was provided via command line, validate and use it
    if [ -n "$ARG_MODULE" ]; then
        local found=false
        for mod in "${modules[@]}"; do
            if [ "$ARG_MODULE" = "$mod" ]; then
                SELECTED_MODULE="$mod"
                found=true
                break
            fi
        done

        if $found; then
            local yaml_file="$MODULE_DIR/$SELECTED_MODULE/module.yaml"
            local name=$(get_yaml_value "$yaml_file" "name")
            mkdir -p "$CACHE_DIR"
            echo "$SELECTED_MODULE" > "$CACHE_MODULE"
            print_success "Module: $name (--module)"
            return
        else
            print_error "Unknown module: $ARG_MODULE"
            echo "Available modules: ${modules[*]}"
            cleanup_modules
            exit 1
        fi
    fi

    # Load cached module (if available)
    local cached_module=""
    if [ -f "$CACHE_MODULE" ]; then
        cached_module=$(cat "$CACHE_MODULE" 2>/dev/null)
    fi

    # Validate cached module still exists
    if [ -n "$cached_module" ]; then
        local found=false
        for mod in "${modules[@]}"; do
            if [ "$mod" = "$cached_module" ]; then
                found=true
                break
            fi
        done
        if ! $found; then
            cached_module=""
        fi
    fi

    # If --yes flag and we have a valid cached module, use it
    if [ "$ARG_YES" = true ] && [ -n "$cached_module" ]; then
        SELECTED_MODULE="$cached_module"
        local yaml_file="$MODULE_DIR/$cached_module/module.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        print_success "Module: $name (cached)"
        return
    fi

    # If --yes flag but no cached module, use first available
    if [ "$ARG_YES" = true ]; then
        SELECTED_MODULE="${modules[0]}"
        local yaml_file="$MODULE_DIR/${modules[0]}/module.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        mkdir -p "$CACHE_DIR"
        echo "$SELECTED_MODULE" > "$CACHE_MODULE"
        print_success "Module: $name (default)"
        return
    fi

    # Interactive selection
    echo ""
    echo -e "${BOLD}Choose your module:${NC}"
    echo ""

    local i=1
    local default_choice=1
    for idx in "${!modules[@]}"; do
        local tagline="${module_taglines[$idx]}"
        if [ -n "$tagline" ]; then
            echo "  $i) ${module_names[$idx]}"
            echo "     ${tagline}"
        else
            echo "  $i) ${module_names[$idx]}"
        fi
        if [ "${modules[$idx]}" = "$cached_module" ]; then
            default_choice=$i
        fi
        i=$((i + 1))
        echo ""
    done

    # Add custom module option
    local custom_option=$i
    echo "  $i) Eigenes Modul"
    echo "     Verwende eines deiner GitHub-Repositories als Vorlage"
    echo ""

    local choice
    choice=$(ask_question "Module" "$default_choice")

    # Check for custom module option
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -eq "$custom_option" ]; then
        if choose_custom_module; then
            return 0
        else
            # If custom module selection failed, ask again
            choose_module
            return
        fi
    fi

    # Check for "eigenes" or "custom" text match
    if [[ "${choice,,}" == *"eigen"* ]] || [[ "${choice,,}" == *"custom"* ]]; then
        if choose_custom_module; then
            return 0
        else
            choose_module
            return
        fi
    fi

    # Handle numeric choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#modules[@]}" ]; then
        SELECTED_MODULE="${modules[$((choice-1))]}"
    else
        # Try to match as ID
        for mod in "${modules[@]}"; do
            if [ "$choice" = "$mod" ]; then
                SELECTED_MODULE="$mod"
                break
            fi
        done
        # Default to first module if no match
        [ -z "$SELECTED_MODULE" ] && SELECTED_MODULE="${modules[0]}"
    fi

    # Cache the module choice
    mkdir -p "$CACHE_DIR"
    echo "$SELECTED_MODULE" > "$CACHE_MODULE"

    local yaml_file="$MODULE_DIR/$SELECTED_MODULE/module.yaml"
    local name=$(get_yaml_value "$yaml_file" "name")
    print_success "Module: $name"
}

# ============================================
# Language Selection (based on selected module)
# ============================================

choose_language() {
    # Skip language selection for custom modules
    if [ "$CUSTOM_MODULE" = true ]; then
        SELECTED_LANGUAGE="custom"
        print_success "Language: from template repository"
        return
    fi

    local module_path="$MODULE_DIR/$SELECTED_MODULE"

    # Get available languages for selected module
    local languages=()
    local lang_names=()

    for lang in $(detect_available_languages "$module_path"); do
        languages+=("$lang")
        local yaml_file="$module_path/$lang/language.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        lang_names+=("$name")
    done

    # If only one language, use it automatically
    if [ "${#languages[@]}" -eq 1 ]; then
        SELECTED_LANGUAGE="${languages[0]}"
        local yaml_file="$module_path/$SELECTED_LANGUAGE/language.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        print_success "Language: $name (only one available)"
        return
    fi

    # If language was provided via command line, validate and use it
    if [ -n "$ARG_LANGUAGE" ]; then
        local matched_lang=$(match_language_alias "$module_path" "$ARG_LANGUAGE")
        if [ -n "$matched_lang" ]; then
            SELECTED_LANGUAGE="$matched_lang"
            local yaml_file="$module_path/$matched_lang/language.yaml"
            local name=$(get_yaml_value "$yaml_file" "name")
            mkdir -p "$CACHE_DIR"
            echo "$SELECTED_LANGUAGE" > "$CACHE_LANGUAGE"
            print_success "Language: $name (--language)"
            return
        else
            print_error "Unknown language for this module: $ARG_LANGUAGE"
            echo "Available languages: ${languages[*]}"
            cleanup_modules
            exit 1
        fi
    fi

    # Load cached language (if available)
    local cached_language=""
    if [ -f "$CACHE_LANGUAGE" ]; then
        cached_language=$(cat "$CACHE_LANGUAGE" 2>/dev/null)
    fi

    # Validate cached language still exists in this module
    if [ -n "$cached_language" ]; then
        local found=false
        for lang in "${languages[@]}"; do
            if [ "$lang" = "$cached_language" ]; then
                found=true
                break
            fi
        done
        if ! $found; then
            cached_language=""
        fi
    fi

    # If --yes flag and we have a valid cached language, use it
    if [ "$ARG_YES" = true ] && [ -n "$cached_language" ]; then
        SELECTED_LANGUAGE="$cached_language"
        local yaml_file="$module_path/$cached_language/language.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        print_success "Language: $name (cached)"
        return
    fi

    # If --yes flag but no cached language, use first available
    if [ "$ARG_YES" = true ]; then
        SELECTED_LANGUAGE="${languages[0]}"
        local yaml_file="$module_path/${languages[0]}/language.yaml"
        local name=$(get_yaml_value "$yaml_file" "name")
        mkdir -p "$CACHE_DIR"
        echo "$SELECTED_LANGUAGE" > "$CACHE_LANGUAGE"
        print_success "Language: $name (default)"
        return
    fi

    # Interactive selection
    echo ""
    echo -e "${BOLD}Choose your language:${NC}"
    echo ""

    local i=1
    local default_choice=1
    for idx in "${!languages[@]}"; do
        echo "  $i) ${lang_names[$idx]}"
        if [ "${languages[$idx]}" = "$cached_language" ]; then
            default_choice=$i
        fi
        i=$((i + 1))
    done
    echo ""

    local choice
    choice=$(ask_question "Language" "$default_choice")

    # Handle numeric choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#languages[@]}" ]; then
        SELECTED_LANGUAGE="${languages[$((choice-1))]}"
    else
        # Try to match as alias
        local matched_lang=$(match_language_alias "$module_path" "$choice")
        if [ -n "$matched_lang" ]; then
            SELECTED_LANGUAGE="$matched_lang"
        else
            # Default to first language
            SELECTED_LANGUAGE="${languages[0]}"
        fi
    fi

    # Cache the language choice
    mkdir -p "$CACHE_DIR"
    echo "$SELECTED_LANGUAGE" > "$CACHE_LANGUAGE"

    local yaml_file="$module_path/$SELECTED_LANGUAGE/language.yaml"
    local name=$(get_yaml_value "$yaml_file" "name")
    print_success "Language: $name"
}

# ============================================
# Checks
# ============================================

check_setup() {
    # Check if Claude Code is installed
    if ! command -v claude &>/dev/null; then
        print_error "Claude Code is not installed."
        echo ""
        echo "Please install Claude Code with:"
        echo '  curl -fsSL https://claude.ai/install.sh | bash'
        echo ""
        exit 1
    fi

    # Check if gh is installed
    if [ -z "$GH_BIN" ] || [ ! -x "$GH_BIN" ]; then
        print_error "GitHub CLI not found."
        echo ""
        echo "Please install GitHub CLI:"
        echo ""
        echo "  Option 1 - Run the bootstrap script:"
        echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ecs-systems/ecs-setup/main/bootstrap.sh)"'
        echo ""
        echo "  Option 2 - Install via package manager:"
        echo "    brew install gh          # macOS"
        echo "    sudo apt install gh      # Debian/Ubuntu"
        echo "    sudo dnf install gh      # Fedora"
        echo ""
        exit 1
    fi

    # Check if logged in
    if ! "$GH_BIN" auth status &>/dev/null; then
        print_warning "You are not logged in to GitHub."
        echo ""

        if confirm "Log in now?"; then
            if [ "$PLATFORM" = "macos" ]; then
                "$GH_BIN" auth login --web --git-protocol https
            else
                "$GH_BIN" auth login --git-protocol https
            fi
        else
            print_error "GitHub login required."
            exit 1
        fi
    fi

    # Get GitHub username
    GH_USER=$("$GH_BIN" api user --jq '.login' 2>/dev/null)
    if [ -z "$GH_USER" ]; then
        print_error "Could not determine GitHub username."
        exit 1
    fi
}

check_access() {
    print_step "Checking access to ECS-Studio..."

    if ! "$GH_BIN" repo view ecs-systems/ecs-studio &>/dev/null; then
        print_error "You do not have access to the ECS-Studio repository."
        echo ""
        echo "Please contact the administrator and share your"
        echo "GitHub username to get access."
        echo ""
        echo "Your GitHub username: $GH_USER"
        echo ""
        exit 1
    fi

    print_success "Access confirmed"
}

check_git_config() {
    print_step "Checking Git configuration..."

    local git_name git_email
    git_name=$(git config --global user.name 2>/dev/null || true)
    git_email=$(git config --global user.email 2>/dev/null || true)

    if [ -n "$git_name" ] && [ -n "$git_email" ]; then
        print_success "Git configured: $git_name <$git_email>"
        return 0
    fi

    print_warning "Git identity not configured."
    echo ""
    echo "Git needs your name and email for commits."
    echo ""

    # Ask for name if not set
    if [ -z "$git_name" ]; then
        # Use author name if already known, otherwise use GitHub username
        local default_name="${AUTHOR_NAME:-$GH_USER}"
        git_name=$(ask_question "Your name for Git commits" "$default_name")
        [ -z "$git_name" ] && git_name="$default_name"
    fi

    # Ask for email if not set
    if [ -z "$git_email" ]; then
        # Try to get email from GitHub
        local gh_email
        gh_email=$("$GH_BIN" api user --jq '.email // empty' 2>/dev/null || true)
        git_email=$(ask_question "Your email for Git commits" "$gh_email")

        while [ -z "$git_email" ]; do
            print_warning "Email is required."
            git_email=$(ask_question "Your email for Git commits" "")
        done
    fi

    # Set git config
    git config --global user.name "$git_name"
    git config --global user.email "$git_email"

    print_success "Git configured: $git_name <$git_email>"
}

# ============================================
# Projekt erstellen
# ============================================

choose_project_name() {
    # If project name was provided via command line, use it
    if [ -n "$ARG_PROJECT" ]; then
        PROJECT_NAME=$(echo "$ARG_PROJECT" | tr -cd '[:alnum:]-_')
        if [ -z "$PROJECT_NAME" ]; then
            print_error "Invalid project name: $ARG_PROJECT"
            exit 1
        fi
    fi

    while true; do
        # Only ask if not provided via command line
        if [ -z "$PROJECT_NAME" ]; then
            echo ""
            PROJECT_NAME=$(ask_question "What should your project be called?" "MyProject")

            # Remove spaces and special characters
            PROJECT_NAME=$(echo "$PROJECT_NAME" | tr -cd '[:alnum:]-_')

            if [ -z "$PROJECT_NAME" ]; then
                PROJECT_NAME="MyProject"
            fi
        fi

        PROJECT_DIR="$ECS_HOME/$PROJECT_NAME"
        REPO_NAME="$GH_USER/$PROJECT_NAME"

        # Check if it already exists locally
        if [ -d "$PROJECT_DIR" ]; then
            # In non-interactive mode, use existing project
            if [ "$ARG_YES" = true ]; then
                print_warning "Project '$PROJECT_NAME' already exists locally."
                USE_EXISTING_LOCAL=true
                return 0
            fi

            print_warning "Project '$PROJECT_NAME' already exists locally."
            echo ""
            echo "  1) Choose a different name"
            echo "  2) Open existing project"
            echo "  3) Update ECS system (from GitHub)"

            # Check if other projects exist
            local other_projects
            other_projects=$(get_other_projects "$PROJECT_NAME")
            local has_other_projects=false
            if [ -n "$other_projects" ]; then
                has_other_projects=true
                echo "  4) Copy ECS system from another project"
            fi

            echo ""
            local choice
            choice=$(ask_question "What would you like to do?" "1")

            case "$choice" in
                2)
                    USE_EXISTING_LOCAL=true
                    return 0
                    ;;
                3)
                    UPDATE_ECS=true
                    return 0
                    ;;
                4)
                    if [ "$has_other_projects" = true ]; then
                        # List other projects
                        echo ""
                        echo "  Available projects:"
                        local i=1
                        local project_array=()
                        while IFS= read -r proj; do
                            echo "    $i) $proj"
                            project_array+=("$proj")
                            i=$((i + 1))
                        done <<< "$other_projects"
                        echo ""

                        local proj_choice
                        proj_choice=$(ask_question "Copy from which project?" "1")

                        # Validate and select project
                        if [[ "$proj_choice" =~ ^[0-9]+$ ]] && [ "$proj_choice" -ge 1 ] && [ "$proj_choice" -le "${#project_array[@]}" ]; then
                            COPY_ECS=true
                            COPY_SOURCE_PROJECT="${project_array[$((proj_choice-1))]}"
                            return 0
                        else
                            print_warning "Invalid selection."
                            PROJECT_NAME=""  # Reset to ask again
                            continue
                        fi
                    else
                        PROJECT_NAME=""  # Reset to ask again
                        continue
                    fi
                    ;;
                *)
                    PROJECT_NAME=""  # Reset to ask again
                    continue
                    ;;
            esac
        fi

        # Check if GitHub repo already exists
        if "$GH_BIN" repo view "$REPO_NAME" &>/dev/null; then
            # In non-interactive mode with --yes, clone existing repo
            if [ "$ARG_YES" = true ]; then
                print_warning "Repository '$REPO_NAME' already exists on GitHub."
                USE_EXISTING_REMOTE=true
                return 0
            fi

            print_warning "Repository '$REPO_NAME' already exists on GitHub."
            echo ""
            echo "  1) Choose a different name"
            echo "  2) Clone existing repo and continue"
            echo ""
            local choice
            choice=$(ask_question "What would you like to do?" "1")

            if [ "$choice" = "2" ]; then
                USE_EXISTING_REMOTE=true
                return 0
            fi
            PROJECT_NAME=""  # Reset to ask again
            continue
        fi

        # Name is available
        USE_EXISTING_LOCAL=false
        USE_EXISTING_REMOTE=false
        return 0
    done
}

clone_existing_repo() {
    print_step "Cloning existing repository..."

    "$GH_BIN" repo clone "$REPO_NAME" "$PROJECT_DIR"

    print_success "Repository cloned"
}

update_ecs_system() {
    local project_dir="$1"
    local module_path="$MODULE_DIR/$SELECTED_MODULE"

    # Detect project language from config or default
    local project_lang="en"
    if [ -f "$project_dir/_bmad/ecs/config.yaml" ]; then
        if grep -q "document_output_language.*Deutsch" "$project_dir/_bmad/ecs/config.yaml" 2>/dev/null; then
            project_lang="de"
        fi
    fi

    # Show warning
    echo ""
    print_warning "The ECS system will be updated."
    echo ""
    echo "  The following folders will be overwritten:"
    echo "    - _bmad/ecs/"
    echo "    - .claude/commands/"
    echo "    - docs/"
    echo ""
    echo -e "  ${YELLOW}Warning:${NC} Custom changes to ECS agents and"
    echo "           ECS workflows will be lost!"
    echo ""
    echo "  Your data will be preserved:"
    echo "    - _bmad/_memory/"
    echo "    - inbox/, content/, output/"
    echo ""

    if ! confirm "Continue?"; then
        echo "Cancelled."
        return 1
    fi

    # Check if module/language is available
    if [ ! -d "$module_path/$project_lang" ]; then
        print_error "Language '$project_lang' not found for module '$SELECTED_MODULE'."
        return 1
    fi

    print_step "Updating ECS system..."

    # Remove old directories
    rm -rf "$project_dir/_bmad/ecs"
    rm -rf "$project_dir/.claude/commands"
    rm -rf "$project_dir/docs"

    # Copy new directories from the correct module/language folder
    cp -r "$module_path/$project_lang/_bmad/ecs" "$project_dir/_bmad/"
    mkdir -p "$project_dir/.claude"
    cp -r "$module_path/$project_lang/.claude/commands" "$project_dir/.claude/"
    [ -d "$module_path/$project_lang/docs" ] && cp -r "$module_path/$project_lang/docs" "$project_dir/"

    print_success "ECS system updated"

    # Git commit
    print_step "Committing changes..."
    cd "$project_dir"
    git add -A
    git commit -m "[ECS] System: Updated to latest version

Co-Authored-By: Claude <noreply@anthropic.com>" 2>/dev/null || print_warning "No changes to commit"

    print_success "Done!"
}

copy_ecs_system() {
    local target_dir="$1"
    local source_project="$2"
    local source_dir="$ECS_HOME/$source_project"

    # Show warning
    echo ""
    print_warning "The ECS system will be copied from '$source_project'."
    echo ""
    echo "  The following folders will be overwritten:"
    echo "    - _bmad/ecs/"
    echo "    - .claude/commands/"
    echo "    - docs/"
    echo ""
    echo -e "  ${YELLOW}Warning:${NC} Custom changes to ECS agents and"
    echo "           ECS workflows will be lost!"
    echo ""
    echo "  Your data will be preserved:"
    echo "    - _bmad/_memory/"
    echo "    - inbox/, content/, output/"
    echo ""

    if ! confirm "Continue?"; then
        echo "Cancelled."
        return 1
    fi

    print_step "Copying ECS system from '$source_project'..."

    # Remove old directories (clean copy)
    rm -rf "$target_dir/_bmad/ecs"
    rm -rf "$target_dir/.claude/commands"
    rm -rf "$target_dir/docs"

    # Copy new directories
    cp -r "$source_dir/_bmad/ecs" "$target_dir/_bmad/"
    mkdir -p "$target_dir/.claude"
    if [ -d "$source_dir/.claude/commands" ]; then
        cp -r "$source_dir/.claude/commands" "$target_dir/.claude/"
    fi
    if [ -d "$source_dir/docs" ]; then
        cp -r "$source_dir/docs" "$target_dir/"
    fi

    print_success "ECS system copied"

    # Git commit
    print_step "Committing changes..."
    cd "$target_dir"
    git add -A
    git commit -m "[ECS] System: Copied from project '$source_project'

Co-Authored-By: Claude <noreply@anthropic.com>" 2>/dev/null || print_warning "No changes to commit"

    print_success "Done!"
}

create_new_project() {
    local module_path="$MODULE_DIR/$SELECTED_MODULE"
    local lang_path="$module_path/$SELECTED_LANGUAGE"

    # For custom modules, use the custom repo directory
    if [ "$CUSTOM_MODULE" = true ]; then
        lang_path="$CUSTOM_REPO_DIR"
    fi

    # Load cached author name (if available)
    local cached_author=""
    if [ -f "$CACHE_AUTHOR" ]; then
        cached_author=$(cat "$CACHE_AUTHOR" 2>/dev/null)
    fi

    # Use command line author if provided
    if [ -n "$ARG_AUTHOR" ]; then
        AUTHOR_NAME="$ARG_AUTHOR"
        print_success "Author: $AUTHOR_NAME (--author)"
    # In non-interactive mode, use cached or fail
    elif [ "$ARG_YES" = true ]; then
        if [ -n "$cached_author" ]; then
            AUTHOR_NAME="$cached_author"
            print_success "Author: $AUTHOR_NAME (cached)"
        else
            print_error "Author name required. Use --author NAME or run interactively."
            exit 1
        fi
    else
        # Ask for author name (with cache as default)
        echo ""
        AUTHOR_NAME=$(ask_question "What is your name?" "$cached_author")

        while [ -z "$AUTHOR_NAME" ]; do
            print_warning "Please enter your name."
            AUTHOR_NAME=$(ask_question "What is your name?" "$cached_author")
        done
    fi

    # Cache author name
    mkdir -p "$CACHE_DIR"
    echo "$AUTHOR_NAME" > "$CACHE_AUTHOR"

    # Get module and language display names
    local module_display
    local lang_display

    if [ "$CUSTOM_MODULE" = true ]; then
        module_display="Eigenes Modul ($CUSTOM_REPO)"
        lang_display="from template"
    else
        local module_yaml="$module_path/module.yaml"
        module_display=$(get_yaml_value "$module_yaml" "name")
        [ -z "$module_display" ] && module_display="$SELECTED_MODULE"

        local lang_yaml="$lang_path/language.yaml"
        lang_display=$(get_yaml_value "$lang_yaml" "name")
        [ -z "$lang_display" ] && lang_display="$SELECTED_LANGUAGE"
    fi

    # Summary
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo -e "${BOLD}Summary:${NC}"
    echo ""
    echo "  Project:       $PROJECT_NAME"
    echo "  Author:        $AUTHOR_NAME"
    if [ "$CUSTOM_MODULE" = true ]; then
        echo "  Template:      $GH_USER/$CUSTOM_REPO"
    else
        echo "  Module:        $module_display"
        echo "  Language:      $lang_display"
    fi
    echo "  Folder:        $PROJECT_DIR"
    echo "  GitHub Repo:   $REPO_NAME"
    echo ""
    echo -e "${CYAN}════════════════════════════════════════════${NC}"
    echo ""

    if ! confirm "Create project?"; then
        echo "Cancelled."
        cleanup_modules
        exit 0
    fi

    echo ""

    # Create project directory
    mkdir -p "$PROJECT_DIR"

    # Copy files from template
    if [ "$CUSTOM_MODULE" = true ]; then
        print_step "Setting up from template '$CUSTOM_REPO'..."
        # Copy all files except .git directory
        rsync -a --exclude='.git' "$CUSTOM_REPO_DIR/" "$PROJECT_DIR/"
    else
        print_step "Setting up $module_display ($lang_display)..."
        cp -r "$lang_path/"* "$PROJECT_DIR/"
        cp -r "$lang_path/".* "$PROJECT_DIR/" 2>/dev/null || true
        # Remove build-time config file (not needed in target project)
        rm -f "$PROJECT_DIR/language.yaml"
    fi

    print_success "Template loaded"

    # Create content folders from language.yaml (only for standard modules)
    if [ "$CUSTOM_MODULE" != true ]; then
        local lang_yaml="$lang_path/language.yaml"

        print_step "Creating content folders..."

        while IFS= read -r folder; do
            [ -z "$folder" ] && continue
            mkdir -p "$PROJECT_DIR/$folder"
            touch "$PROJECT_DIR/$folder/.gitkeep"
        done < <(get_yaml_array "$lang_yaml" "folders")

        # Create inbox README from language.yaml
        local inbox_readme=$(get_yaml_multiline "$lang_yaml" "inbox_readme")
        if [ -n "$inbox_readme" ]; then
            echo "$inbox_readme" > "$PROJECT_DIR/inbox/README.md"
        fi

        print_success "Content folders created"
    fi

    # Configure project
    print_step "Configuring project..."

    # Update CLAUDE.md with author name
    if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
        sed_inplace "s/{{AUTHOR_NAME}}/$AUTHOR_NAME/g" "$PROJECT_DIR/CLAUDE.md" 2>/dev/null || true
    fi

    # Update BMAD config.yaml with author name
    if [ -f "$PROJECT_DIR/_bmad/core/config.yaml" ]; then
        sed_inplace "s/{{AUTHOR_NAME}}/$AUTHOR_NAME/g" "$PROJECT_DIR/_bmad/core/config.yaml" 2>/dev/null || true
    fi

    # Create config.yaml from language.yaml template (only for standard modules)
    if [ "$CUSTOM_MODULE" != true ]; then
        local lang_yaml="$lang_path/language.yaml"
        local config_dir="$PROJECT_DIR/_bmad/ecs"
        if [ -d "$config_dir" ]; then
            local config_template=$(get_yaml_multiline "$lang_yaml" "config_template")
            if [ -n "$config_template" ]; then
                # Replace placeholders
                config_template=$(echo "$config_template" | sed "s/{{AUTHOR_NAME}}/$AUTHOR_NAME/g")
                config_template=$(echo "$config_template" | sed "s/{{PROJECT_NAME}}/$PROJECT_NAME/g")
                config_template=$(echo "$config_template" | sed "s/{{DATE}}/$(date '+%Y-%m-%d')/g")
                echo "$config_template" > "$config_dir/config.yaml"
            fi
        fi
    fi

    print_success "Project configured"

    # Initialize Git
    print_step "Initializing Git..."

    cd "$PROJECT_DIR"
    git init -q
    git add -A

    if [ "$CUSTOM_MODULE" = true ]; then
        git commit -q -m "Project '$PROJECT_NAME' created from template

Template: $GH_USER/$CUSTOM_REPO
Author: $AUTHOR_NAME

Co-Authored-By: Claude <noreply@anthropic.com>"
    else
        git commit -q -m "Project '$PROJECT_NAME' created

Module: $module_display
Author: $AUTHOR_NAME
Language: $lang_display

Co-Authored-By: Claude <noreply@anthropic.com>"
    fi

    print_success "Git initialized"

    # Create GitHub repo
    print_step "Creating GitHub repository..."

    "$GH_BIN" repo create "$PROJECT_NAME" --private --source=. --remote=origin --push

    print_success "GitHub repository created: $REPO_NAME"
}

# ============================================
# Main Program
# ============================================

main() {
    # Parse command line arguments first
    parse_args "$@"

    # --version: Show version and exit
    if [ "$ARG_VERSION" = true ]; then
        echo "ECS-Setup version $SETUP_VERSION"
        exit 0
    fi

    # --update: Explicit update
    if [ "$ARG_UPDATE" = true ]; then
        echo ""
        echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}     ${BOLD}ECS-Setup — Update${NC}                     ${CYAN}║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
        echo ""
        echo "Current version: $SETUP_VERSION"
        echo ""
        perform_update "$@"
        exit 0
    fi

    print_header

    # Auto-update check (unless disabled)
    if [ "$ARG_NO_UPDATE_CHECK" != true ]; then
        local new_version
        new_version=$(check_for_updates) || true
        if [ -n "$new_version" ]; then
            print_warning "New version available: $new_version (current: $SETUP_VERSION)"
            if confirm "Update now?"; then
                perform_update "$@"
            fi
            echo ""
        fi
    fi

    # Show parameters if any were provided
    if [ -n "$ARG_PROJECT" ] || [ -n "$ARG_AUTHOR" ] || [ -n "$ARG_MODULE" ] || [ -n "$ARG_LANGUAGE" ] || [ "$ARG_YES" = true ]; then
        echo -e "${BLUE}Parameters:${NC}"
        [ -n "$ARG_PROJECT" ] && echo "  --project: $ARG_PROJECT"
        [ -n "$ARG_AUTHOR" ] && echo "  --author: $ARG_AUTHOR"
        [ -n "$ARG_MODULE" ] && echo "  --module: $ARG_MODULE"
        [ -n "$ARG_LANGUAGE" ] && echo "  --language: $ARG_LANGUAGE"
        [ "$ARG_YES" = true ] && echo "  --yes: enabled"
        echo ""
    fi

    check_setup
    check_access
    check_git_config
    load_modules
    choose_module        # Module selection FIRST
    choose_language      # THEN: Language selection (based on module)
    choose_project_name

    if [ "$UPDATE_ECS" = true ]; then
        update_ecs_system "$PROJECT_DIR"
    elif [ "$COPY_ECS" = true ]; then
        copy_ecs_system "$PROJECT_DIR" "$COPY_SOURCE_PROJECT"
    elif [ "$USE_EXISTING_LOCAL" = true ]; then
        echo ""
        print_success "Using existing project: $PROJECT_DIR"
    elif [ "$USE_EXISTING_REMOTE" = true ]; then
        clone_existing_repo
    else
        create_new_project
    fi

    # Completion message
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Done! Your project is ready.${NC}"
    echo ""
    echo "  Start your project:"
    echo ""
    echo -e "    ${CYAN}cd \"$PROJECT_DIR\"${NC}"
    echo -e "    ${CYAN}claude${NC}"
    echo ""

    # Show workflows from language.yaml (only for standard modules)
    if [ "$CUSTOM_MODULE" != true ]; then
        local module_path="$MODULE_DIR/$SELECTED_MODULE"
        local lang_yaml="$module_path/$SELECTED_LANGUAGE/language.yaml"

        # Check if we have example workflows
        if grep -q "^example_workflows:" "$lang_yaml" 2>/dev/null; then
            echo "  Available Workflows:"

            # Parse example_workflows (simple format: - command: "...", description: "...")
            local in_workflows=false
            local current_command=""
            while IFS= read -r line; do
                if [[ "$line" =~ ^example_workflows: ]]; then
                    in_workflows=true
                    continue
                fi

                if $in_workflows; then
                    # Exit if we hit another root-level key
                    if [[ "$line" =~ ^[a-z_]+: ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
                        break
                    fi

                    # Extract command
                    if [[ "$line" =~ command:[[:space:]]*\"([^\"]+)\" ]]; then
                        current_command="${BASH_REMATCH[1]}"
                    fi

                    # Extract description and print
                    if [[ "$line" =~ description:[[:space:]]*\"([^\"]+)\" ]] && [ -n "$current_command" ]; then
                        local desc="${BASH_REMATCH[1]}"
                        printf "    %-28s — %s\n" "$current_command" "$desc"
                        current_command=""
                    fi
                fi
            done < "$lang_yaml"
        fi
    else
        echo "  Your project was created from template: $CUSTOM_REPO"
    fi

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo "  To start Claude Code, run:"
    echo ""
    echo -e "    ${CYAN}cd $PROJECT_NAME${NC}"
    echo -e "    ${CYAN}claude${NC}"
    echo ""

    # Cleanup modules
    cleanup_modules
}

main "$@"

# vim: set ts=4 sw=4 et:
