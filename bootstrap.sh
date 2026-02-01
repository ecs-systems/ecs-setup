#!/bin/bash
# ============================================
# ECS-Studio — Bootstrap
# Creates ~/ECS-Studio and installs tools
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

ECS_HOME="$HOME/ECS-Studio"
TOOLS_DIR="$ECS_HOME/.tools"
GH_DIR="$TOOLS_DIR/gh"
GH_BIN="$GH_DIR/bin/gh"

# Detect platform (Linux, macOS, WSL)
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

# ============================================
# Helper Functions
# ============================================

print_header() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}     ${BOLD}ECS-Studio - Setup${NC}                     ${CYAN}║${NC}"
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

confirm() {
    local prompt="$1"
    local response
    echo -ne "${CYAN}?${NC} ${prompt} ${BOLD}[Y/n]${NC}: "
    read -r response
    case "$response" in
        [nN]|[nN][oO]) return 1 ;;
        *) return 0 ;;
    esac
}

# ============================================
# Checks
# ============================================

check_dependencies() {
    print_step "Checking dependencies..."

    local missing=()

    # Check curl
    if ! command -v curl &> /dev/null; then
        missing+=("curl")
    fi

    # Check unzip (only needed on macOS for GitHub CLI installation)
    # Linux/WSL uses tar.gz format, so unzip is not required there
    if [ "$PLATFORM" = "macos" ] && ! command -v unzip &> /dev/null; then
        missing+=("unzip")
    fi

    # Check git
    if ! command -v git &> /dev/null; then
        missing+=("git")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        print_error "Missing dependencies: ${missing[*]}"
        echo ""
        echo "Please install the missing packages:"
        echo ""

        case "$PLATFORM" in
            macos)
                echo -e "  ${CYAN}xcode-select --install${NC}   # for git"
                echo -e "  ${CYAN}brew install ${missing[*]}${NC}"
                ;;
            wsl|linux)
                echo -e "  ${CYAN}sudo apt install ${missing[*]}${NC}     # Debian/Ubuntu"
                echo -e "  ${CYAN}sudo dnf install ${missing[*]}${NC}     # Fedora/RHEL"
                echo -e "  ${CYAN}sudo pacman -S ${missing[*]}${NC}       # Arch Linux"
                ;;
            *)
                echo -e "  Install: ${missing[*]}"
                ;;
        esac

        echo ""
        exit 1
    fi

    print_success "All dependencies available"
}

check_platform() {
    print_step "Checking operating system..."

    case "$PLATFORM" in
        macos)
            local macos_version
            macos_version=$(sw_vers -productVersion)
            local major_version
            major_version=$(echo "$macos_version" | cut -d. -f1)

            if [ "$major_version" -lt 12 ]; then
                print_error "macOS 12 (Monterey) or newer is required."
                exit 1
            fi
            print_success "macOS $macos_version"
            ;;
        linux)
            print_success "Linux ($(uname -r))"
            ;;
        wsl)
            print_success "Windows WSL ($(uname -r))"
            ;;
        *)
            print_warning "Unknown system: $OSTYPE"
            print_warning "The script might still work."
            ;;
    esac
}

check_xcode_clt() {
    # Only relevant on macOS
    if [ "$PLATFORM" != "macos" ]; then
        return 0
    fi

    print_step "Checking Xcode Command Line Tools..."

    if ! xcode-select -p &>/dev/null; then
        print_warning "Xcode Command Line Tools are required."
        echo ""
        echo -e "${YELLOW}We need to install some tools from Apple - about 1.5 GB.${NC}"
        echo -e "${YELLOW}A popup window will appear. Find it! Then click 'Install'.${NC}"
        echo ""
        xcode-select --install

        echo ""
        while true; do
            echo -e "${YELLOW}Press ENTER after the installation is complete...${NC}"
            read -r

            if xcode-select -p &>/dev/null; then
                break
            fi

            print_warning "Installation not yet complete. Please wait..."
            echo ""
        done
    fi

    print_success "Xcode Command Line Tools installed"
}

# ============================================
# Installation
# ============================================

create_directories() {
    print_step "Creating ECS-Studio directory..."

    mkdir -p "$TOOLS_DIR"
    mkdir -p "$GH_DIR"

    print_success "$ECS_HOME created"
}

install_gh() {
    print_step "Installing GitHub CLI..."

    # Check if already installed locally
    if [ -x "$GH_BIN" ]; then
        print_success "GitHub CLI already installed (local)"
        return 0
    fi

    # Check if already installed system-wide
    if command -v gh &> /dev/null; then
        local system_gh=$(command -v gh)
        local gh_ver=$(gh --version 2>/dev/null | head -1)
        print_success "GitHub CLI already installed: $system_gh"
        print_success "$gh_ver"
        # Create symlink so setup.sh can find it
        mkdir -p "$GH_DIR/bin"
        ln -sf "$system_gh" "$GH_BIN"
        return 0
    fi

    local gh_version="2.65.0"
    local arch
    local os_name
    local archive_ext
    local extract_cmd

    # Determine architecture
    case "$(uname -m)" in
        arm64|aarch64) arch="arm64" ;;
        x86_64) arch="amd64" ;;
        i386|i686) arch="386" ;;
        *)
            print_error "Unknown architecture: $(uname -m)"
            exit 1
            ;;
    esac

    # Determine operating system and archive format
    case "$PLATFORM" in
        macos)
            os_name="macOS"
            archive_ext="zip"
            ;;
        linux|wsl)
            os_name="linux"
            archive_ext="tar.gz"
            ;;
        *)
            print_error "Unknown operating system: $PLATFORM"
            exit 1
            ;;
    esac

    local gh_archive="gh_${gh_version}_${os_name}_${arch}.${archive_ext}"
    local gh_url="https://github.com/cli/cli/releases/download/v${gh_version}/${gh_archive}"
    local tmp_dir="/tmp/gh-install-$$"

    mkdir -p "$tmp_dir"

    print_step "Downloading gh v${gh_version}..."

    if curl -fsSL "$gh_url" -o "$tmp_dir/$gh_archive"; then
        # Extract based on format
        if [ "$archive_ext" = "zip" ]; then
            unzip -q "$tmp_dir/$gh_archive" -d "$tmp_dir"
        else
            tar -xzf "$tmp_dir/$gh_archive" -C "$tmp_dir"
        fi

        cp -r "$tmp_dir/gh_${gh_version}_${os_name}_${arch}/"* "$GH_DIR/"
        chmod +x "$GH_BIN"
        rm -rf "$tmp_dir"
        print_success "GitHub CLI installed"
    else
        print_error "Download failed"
        rm -rf "$tmp_dir"
        exit 1
    fi
}

download_setup_script() {
    print_step "Downloading setup script..."

    local setup_url="https://raw.githubusercontent.com/ecs-systems/ecs-setup/main/setup.sh"

    if curl -fsSL "$setup_url" -o "$TOOLS_DIR/setup.sh"; then
        chmod +x "$TOOLS_DIR/setup.sh"
        print_success "Setup script installed"
    else
        print_error "Download failed"
        exit 1
    fi

    # Create symlink
    ln -sf ".tools/setup.sh" "$ECS_HOME/setup"
    print_success "Shortcut created: ~/ECS-Studio/setup"
}

create_desktop_shortcut() {
    # Only on WSL
    if [ "$PLATFORM" != "wsl" ]; then
        return 0
    fi

    print_step "Creating desktop shortcut..."

    # Get Windows username (remove trailing \r from PowerShell output)
    local win_user
    win_user=$(powershell.exe -NoProfile -Command '[System.Environment]::UserName' 2>/dev/null | tr -d '\r')

    if [ -z "$win_user" ]; then
        print_warning "Could not detect Windows username"
        return 0
    fi

    local win_desktop="/mnt/c/Users/${win_user}/Desktop"

    if [ ! -d "$win_desktop" ]; then
        print_warning "Desktop folder not found: $win_desktop"
        return 0
    fi

    # Check if Windows Terminal is available (standard on Windows 11, optional on Windows 10)
    local use_wt=false
    if powershell.exe -NoProfile -Command "Get-Command wt.exe -ErrorAction SilentlyContinue" &>/dev/null; then
        use_wt=true
    fi

    # Create shortcut via PowerShell
    if [ "$use_wt" = true ]; then
        # Use Windows Terminal (keeps window open, better experience)
        if powershell.exe -NoProfile -Command "
\$ws = New-Object -ComObject WScript.Shell
\$s = \$ws.CreateShortcut('C:\\Users\\${win_user}\\Desktop\\ECS-Studio.lnk')
\$s.TargetPath = 'wt.exe'
\$s.Arguments = 'wsl.exe --cd ~/ECS-Studio'
\$s.Description = 'Open ECS-Studio Terminal'
\$s.Save()
" 2>/dev/null; then
            print_success "Desktop shortcut created: ECS-Studio.lnk (Windows Terminal)"
        else
            print_warning "Could not create desktop shortcut"
        fi
    else
        # Fallback without Windows Terminal: create a batch file wrapper
        local batch_file="/mnt/c/Users/${win_user}/ECS-Studio.cmd"
        cat > "$batch_file" << 'BATCH'
@echo off
wsl.exe --cd ~/ECS-Studio
BATCH

        if powershell.exe -NoProfile -Command "
\$ws = New-Object -ComObject WScript.Shell
\$s = \$ws.CreateShortcut('C:\\Users\\${win_user}\\Desktop\\ECS-Studio.lnk')
\$s.TargetPath = 'C:\\Users\\${win_user}\\ECS-Studio.cmd'
\$s.Description = 'Open ECS-Studio Terminal'
\$s.Save()
" 2>/dev/null; then
            print_success "Desktop shortcut created: ECS-Studio.lnk"
        else
            print_warning "Could not create desktop shortcut"
        fi
    fi
}

github_login() {
    print_step "GitHub login..."

    # Check if already logged in
    if "$GH_BIN" auth status &>/dev/null; then
        print_success "Already logged in to GitHub"
        return 0
    fi

    echo ""

    local login_result=false

    if [ "$PLATFORM" = "macos" ]; then
        # macOS: Browser opens automatically
        echo -e "${YELLOW}A browser window will open.${NC}"
        echo -e "${YELLOW}Please log in to GitHub and authorize access.${NC}"
        echo -e "${YELLOW}Press ENTER now.${NC}"
        read -r

        if "$GH_BIN" auth login --web --git-protocol https; then
            login_result=true
        fi
    else
        # WSL/Linux: Browser cannot open automatically, use device flow
        echo -e "${YELLOW}You will receive a code and a URL.${NC}"
        echo -e "${YELLOW}Open the URL in your browser and enter the code.${NC}"
        echo -e "${YELLOW}Press ENTER to continue.${NC}"
        read -r

        if "$GH_BIN" auth login --git-protocol https; then
            login_result=true
        fi
    fi

    if [ "$login_result" = true ]; then
        print_success "GitHub login successful"
    else
        print_error "GitHub login failed"
        echo ""
        echo "You can try again later with:"
        echo "  $GH_BIN auth login"
        echo ""
    fi
}

# ============================================
# Main Program
# ============================================

main() {
    print_header

    echo "This setup creates:"
    echo "  • ~/ECS-Studio/ - one directory per project"
    echo "  • GitHub CLI"
    if [ "$PLATFORM" = "macos" ]; then
        echo "  • Xcode CLI Tools from Apple (if needed)"
    fi
    echo "  • Setup script for new projects"
    if [ "$PLATFORM" = "wsl" ]; then
        echo "  • Desktop shortcut for ECS-Studio"
    fi
    echo ""

    if ! confirm "Do you want to continue?"; then
        echo "Cancelled."
        exit 0
    fi

    echo ""

    check_dependencies
    check_platform
    check_xcode_clt
    create_directories
    install_gh
    download_setup_script
    create_desktop_shortcut
    github_login

    # Completion
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}Done! Your ECS-Studio is ready.${NC}"
    echo ""
    echo "  Next step — Create your first project:"
    echo ""
    echo -e "    ${CYAN}cd ~/ECS-Studio${NC}"
    echo -e "    ${CYAN}./setup${NC}"
    if [ "$PLATFORM" = "wsl" ]; then
        echo ""
        echo "  Or use the desktop shortcut: ECS-Studio.lnk"
    fi
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
}

main "$@"
