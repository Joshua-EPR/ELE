#!/bin/sh
# scripts/install.sh
# Native User Installer for the ELE Language (Linux x86-64)
#
# Installs standalone, zero-CRT native ELE compiler directly into ~/.ele
# and safely configures user PATH in ~/.bashrc or ~/.profile.
# Does NOT require root/sudo.
# Does NOT overwrite existing PATH entries.

set -e

INSTALL_DIR="${INSTALL_DIR:-$HOME/.ele}"
PACKAGE_PATH=""
UPDATE_PATH=1
RUN_VERIFICATION=1

show_help() {
    echo "ELE Linux Installer"
    echo "Usage: ./install.sh [options]"
    echo ""
    echo "Options:"
    echo "  --prefix, -d <dir>    Install directory (default: ~/.ele)"
    echo "  --package, -p <file>  Path to ele-linux-x86_64.tar.gz"
    echo "  --no-path             Do not modify shell profile PATH"
    echo "  --skip-verify         Skip post-install verification smoke tests"
    echo "  --help, -h            Show this help message"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix|-d)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --package|-p)
            PACKAGE_PATH="$2"
            shift 2
            ;;
        --no-path)
            UPDATE_PATH=0
            shift
            ;;
        --skip-verify)
            RUN_VERIFICATION=0
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "============================================================"
echo " ELE Programming Language — Native Linux Installer"
echo "============================================================"
echo "[install] Target directory: $INSTALL_DIR"

# 1. Locate archive or package
ARCHIVE=""
if [ -n "$PACKAGE_PATH" ] && [ -f "$PACKAGE_PATH" ]; then
    ARCHIVE="$PACKAGE_PATH"
elif [ -f "$REPO_ROOT/dist/ele-linux-x86_64.tar.gz" ]; then
    ARCHIVE="$REPO_ROOT/dist/ele-linux-x86_64.tar.gz"
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/bin"
mkdir -p "$INSTALL_DIR/examples"

if [ -n "$ARCHIVE" ]; then
    echo "[install] Extracting package: $ARCHIVE"
    TMP_EXTRACT="$(mktemp -d)"
    tar -xzf "$ARCHIVE" -C "$TMP_EXTRACT"
    SOURCE_DIR="$TMP_EXTRACT/ele"
    if [ ! -d "$SOURCE_DIR" ]; then
        SOURCE_DIR="$TMP_EXTRACT"
    fi

    cp -f "$SOURCE_DIR/bin/"* "$INSTALL_DIR/bin/"
    if [ -d "$SOURCE_DIR/examples" ]; then
        cp -rf "$SOURCE_DIR/examples/"* "$INSTALL_DIR/examples/"
    fi
    for doc in README.md README.es.md VERSION; do
        if [ -f "$SOURCE_DIR/$doc" ]; then
            cp -f "$SOURCE_DIR/$doc" "$INSTALL_DIR/$doc"
        fi
    done
    rm -rf "$TMP_EXTRACT"
else
    echo "[install] Archive not found. Generating package or copying repo files..."
    if [ -f "$REPO_ROOT/scripts/package_distribution.py" ]; then
        python3 "$REPO_ROOT/scripts/package_distribution.py" --target linux
        ARCHIVE="$REPO_ROOT/dist/ele-linux-x86_64.tar.gz"
        TMP_EXTRACT="$(mktemp -d)"
        tar -xzf "$ARCHIVE" -C "$TMP_EXTRACT"
        cp -f "$TMP_EXTRACT/ele/bin/"* "$INSTALL_DIR/bin/"
        if [ -d "$TMP_EXTRACT/ele/examples" ]; then
            cp -rf "$TMP_EXTRACT/ele/examples/"* "$INSTALL_DIR/examples/"
        fi
        for doc in README.md README.es.md VERSION; do
            if [ -f "$TMP_EXTRACT/ele/$doc" ]; then
                cp -f "$TMP_EXTRACT/ele/$doc" "$INSTALL_DIR/$doc"
            fi
        done
        rm -rf "$TMP_EXTRACT"
    elif [ -f "$REPO_ROOT/bin/ele.elf" ]; then
        cp -f "$REPO_ROOT/bin/ele.elf" "$INSTALL_DIR/bin/ele"
        cp -rf "$REPO_ROOT/examples/"* "$INSTALL_DIR/examples/"
        for doc in README.md README.es.md VERSION; do
            if [ -f "$REPO_ROOT/$doc" ]; then
                cp -f "$REPO_ROOT/$doc" "$INSTALL_DIR/$doc"
            fi
        done
    else
        echo "Error: Could not locate ELE distribution package or binary." >&2
        exit 1
    fi
fi

# 2. Set executable permissions
chmod 755 "$INSTALL_DIR/bin/ele"
echo "[install] Executable configured: $INSTALL_DIR/bin/ele"

# 3. Configure PATH safely
if [ "$UPDATE_PATH" -eq 1 ]; then
    echo "[install] Configuring PATH in shell profiles..."
    BIN_DIR="$INSTALL_DIR/bin"
    PATH_LINE="export PATH=\"$BIN_DIR:\$PATH\""
    
    UPDATED=0
    for profile in "$HOME/.bashrc" "$HOME/.profile" "$HOME/.zshrc"; do
        if [ -f "$profile" ]; then
            if ! grep -q "$BIN_DIR" "$profile" && ! grep -q '\.ele/bin' "$profile"; then
                echo "" >> "$profile"
                echo "# ELE programming language" >> "$profile"
                echo "$PATH_LINE" >> "$profile"
                echo "  -> Added to $profile"
                UPDATED=1
            else
                echo "  -> Already present in $profile"
            fi
        fi
    done

    if [ "$UPDATED" -eq 0 ] && [ ! -f "$HOME/.profile" ]; then
        echo "$PATH_LINE" >> "$HOME/.profile"
        echo "  -> Created $HOME/.profile with PATH update"
    fi
    
    export PATH="$BIN_DIR:$PATH"
fi

# 4. Self-Verification
if [ "$RUN_VERIFICATION" -eq 1 ]; then
    echo ""
    echo "[verify] Running post-installation self-verification..."
    
    # 4a. Check --version
    VER_OUT="$("$INSTALL_DIR/bin/ele" --version)"
    echo "  -> ele --version: $VER_OUT [OK]"
    
    # 4b. Check --help
    "$INSTALL_DIR/bin/ele" --help >/dev/null
    echo "  -> ele --help: CLI driver responsive [OK]"
    
    # 4c. Compile and run sample program
    TMP_VERIFY="$(mktemp -d)"
    SAMPLE_SRC="$TMP_VERIFY/hello_verify.l"
    SAMPLE_BIN="$TMP_VERIFY/hello_verify"
    
    cat << 'EOF' > "$SAMPLE_SRC"
flow main() => Int {
    print("Hello from native ELE Linux installer verification")
    give 0
}
EOF

    "$INSTALL_DIR/bin/ele" build "$SAMPLE_SRC" --target elf --output "$SAMPLE_BIN"
    chmod 755 "$SAMPLE_BIN"
    SAMPLE_OUT="$("$SAMPLE_BIN")"
    
    if [ "$SAMPLE_OUT" != "Hello from native ELE Linux installer verification" ]; then
        echo "Self-verification failed: unexpected sample output: $SAMPLE_OUT" >&2
        rm -rf "$TMP_VERIFY"
        exit 1
    fi
    echo "  -> Execution of native ELF64 binary: '$SAMPLE_OUT' [OK]"
    rm -rf "$TMP_VERIFY"
fi

echo ""
echo "============================================================"
echo " ELE Installation Completed Successfully!"
echo "============================================================"
echo "Location: $INSTALL_DIR"
echo "Binary:   $INSTALL_DIR/bin/ele"
echo ""
echo "To get started:"
echo "  export PATH=\"$INSTALL_DIR/bin:\$PATH\"   # (or restart your terminal)"
echo "  ele build hello.l -o hello"
echo "  ele --help"
echo "============================================================"
