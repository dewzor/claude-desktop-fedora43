#!/bin/bash
set -e

# =============================================================================
# Claude Desktop for Fedora 43+ - Complete Build Script
#
# Fixes included:
#   - Auto-download latest version from redirect URL
#   - Layout scaling (main_window.tgz patch)
#   - Native window frame (no custom titlebar issues)
#   - Menu bar FULLY removed
#   - Window maximize/resize fix (forced relayout)
#   - Google Sign-In (native module stub)
#   - Origin validation bypass (IPC security fix for file:// URLs)
#   - GPU/Wayland compatibility (software rendering fallback)
#   - Titlebar gap fix via grid collapse + element removal (v7)
#
# v7 Changelog:
#   - Fixed dark titlebar gap by collapsing CSS grid rows
#   - Changed from display:none to element.remove() for titlebar
#   - Added -webkit-app-region:drag detection (survives minification)
#   - Removed redundant CSS file patching
# =============================================================================

# Use redirect URL for always-latest version
CLAUDE_DOWNLOAD_URL="https://claude.ai/api/desktop/win32/x64/exe/latest/redirect"
ELECTRON_VERSION=${ELECTRON_VERSION:-"37.0.0"}
ELECTRON_DOWNLOAD_URL=${ELECTRON_DOWNLOAD_URL:-"https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip"}
MAIN_WINDOW_FIX_URL="https://github.com/emsi/claude-desktop/raw/refs/heads/main/assets/main_window.tgz"

is_fedora_based() {
    [ -f "/etc/fedora-release" ] && return 0
    [ -f "/etc/os-release" ] && grep -qi "fedora" /etc/os-release && return 0
    return 1
}

if ! is_fedora_based; then
    echo "This script requires a Fedora-based Linux distribution"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run with sudo"
    exit 1
fi

if [ -n "$SUDO_USER" ]; then
    ORIGINAL_USER="$SUDO_USER"
    ORIGINAL_HOME=$(eval echo ~$ORIGINAL_USER)
else
    ORIGINAL_USER="root"
    ORIGINAL_HOME="/root"
fi

# Preserve NVM path
if [ "$ORIGINAL_USER" != "root" ] && [ -d "$ORIGINAL_HOME/.nvm" ]; then
    export NVM_DIR="$ORIGINAL_HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    NODE_BIN_PATH=$(find "$NVM_DIR/versions/node" -maxdepth 2 -type d -name 'bin' 2>/dev/null | sort -V | tail -n 1)
    [ -n "$NODE_BIN_PATH" ] && [ -d "$NODE_BIN_PATH" ] && export PATH="$NODE_BIN_PATH:$PATH"
fi

echo "============================================================================"
echo "Claude Desktop for Fedora - Build Script v7"
echo "============================================================================"
echo "Distribution: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
echo "============================================================================"

# Check dependencies
check_command() {
    command -v "$1" &> /dev/null && echo "✓ $1" && return 0
    echo "✗ $1 not found" && return 1
}

DEPS_TO_INSTALL=""
for cmd in sqlite3 7z wget curl unzip wrestool icotool convert npx rpmbuild file; do
    if ! check_command "$cmd"; then
        case "$cmd" in
            "sqlite3") DEPS_TO_INSTALL="$DEPS_TO_INSTALL sqlite3" ;;
            "7z") DEPS_TO_INSTALL="$DEPS_TO_INSTALL p7zip-plugins" ;;
            "wget") DEPS_TO_INSTALL="$DEPS_TO_INSTALL wget" ;;
            "curl") DEPS_TO_INSTALL="$DEPS_TO_INSTALL curl" ;;
            "unzip") DEPS_TO_INSTALL="$DEPS_TO_INSTALL unzip" ;;
            "wrestool"|"icotool") DEPS_TO_INSTALL="$DEPS_TO_INSTALL icoutils" ;;
            "convert") DEPS_TO_INSTALL="$DEPS_TO_INSTALL ImageMagick" ;;
            "npx") DEPS_TO_INSTALL="$DEPS_TO_INSTALL nodejs npm" ;;
            "rpmbuild") DEPS_TO_INSTALL="$DEPS_TO_INSTALL rpm-build" ;;
            "file") DEPS_TO_INSTALL="$DEPS_TO_INSTALL file" ;;
        esac
    fi
done

[ -n "$DEPS_TO_INSTALL" ] && dnf install -y $DEPS_TO_INSTALL

PACKAGE_NAME="claude-desktop"
ARCHITECTURE=$(uname -m)
DISTRIBUTION=$(rpm --eval %{?dist})
MAINTAINER="Claude Desktop Linux Maintainers"

# Create working directories
WORK_DIR="$(pwd)/build"
FEDORA_ROOT="$WORK_DIR/fedora-package"
INSTALL_DIR="$FEDORA_ROOT/usr"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
mkdir -p "$FEDORA_ROOT/FEDORA"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME"
mkdir -p "$INSTALL_DIR/share/applications"
mkdir -p "$INSTALL_DIR/share/icons"
mkdir -p "$INSTALL_DIR/bin"

# Install asar if needed
if ! command -v asar > /dev/null 2>&1; then
    npm install -g asar
fi

# Download Claude with Cloudflare bypass
echo "📥 Downloading Claude Desktop (latest version)..."
CLAUDE_EXE="$WORK_DIR/Claude-Setup-x64.exe"
USER_AGENT="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

if ! curl --fail -L --retry 3 \
    -H "User-Agent: ${USER_AGENT}" \
    -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8" \
    -H "Accept-Language: en-US,en;q=0.5" \
    -H "Sec-Fetch-Dest: document" \
    -H "Sec-Fetch-Mode: navigate" \
    --compressed \
    -o "$CLAUDE_EXE" \
    "$CLAUDE_DOWNLOAD_URL"; then
    echo "Download failed"
    exit 1
fi

# Verify we downloaded an actual executable, not an error page
if ! file "$CLAUDE_EXE" | grep -q "PE32\|executable"; then
    echo "❌ Downloaded file is not a valid Windows executable"
    echo "   File type: $(file "$CLAUDE_EXE")"
    echo "   This usually means Cloudflare blocked the download."
    echo ""
    echo "   Workaround: Manually download the installer from https://claude.ai/download"
    echo "   Then update CLAUDE_DOWNLOAD_URL in this script to point to your local file."
    exit 1
fi

echo "✓ Download complete"

# Extract
echo "📦 Extracting..."
cd "$WORK_DIR"
7z x -y "$CLAUDE_EXE" || { echo "Extract failed"; exit 1; }

NUPKG_FILE=$(find . -name "AnthropicClaude-*-full.nupkg" | head -1)
[ -z "$NUPKG_FILE" ] && { echo "nupkg not found"; exit 1; }

VERSION=$(echo "$NUPKG_FILE" | grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full\.nupkg)')
echo "📋 Detected Claude version: $VERSION"

7z x -y "$NUPKG_FILE" || { echo "nupkg extract failed"; exit 1; }

# Download Electron
echo "📥 Downloading Electron v${ELECTRON_VERSION}..."
curl -L -o "$WORK_DIR/electron.zip" "$ELECTRON_DOWNLOAD_URL" || { echo "Electron download failed"; exit 1; }
unzip -q "$WORK_DIR/electron.zip" -d "$WORK_DIR/electron-dist"
echo "✓ Electron ready"

# Extract icons
echo "🎨 Processing icons..."
wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico || { echo "Icon extract failed"; exit 1; }
icotool -x claude.ico || { echo "Icon convert failed"; exit 1; }

declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png"
    ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png"
    ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png"
    ["256"]="claude_6_256x256x32.png"
)

for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    [ -f "${icon_files[$size]}" ] && install -Dm 644 "${icon_files[$size]}" "$icon_dir/claude-desktop.png"
done

# Process app.asar
mkdir -p electron-app
cp "lib/net45/resources/app.asar" electron-app/
cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

cd electron-app
npx asar extract app.asar app.asar.contents || { echo "asar extract failed"; exit 1; }

# =============================================================================
# FIX 1: Apply main_window patch (optional layout fix)
# =============================================================================
echo "🔧 Applying main_window patch..."
wget -O- "$MAIN_WINDOW_FIX_URL" 2>/dev/null | tar -zxvf - -C app.asar.contents/ 2>/dev/null || echo "⚠️ main_window.tgz patch skipped"

# =============================================================================
# FIX 2: Stable titleBarStyle sed (Electron API - reliable across versions)
# =============================================================================
echo "🔧 Applying stable titleBarStyle fix..."
TARGET_FILE="app.asar.contents/.vite/build/index.js"

if [ -f "$TARGET_FILE" ]; then
    if grep -qF 'titleBarStyle:"hidden"' "$TARGET_FILE"; then
        sed -i 's/titleBarStyle:"hidden"/titleBarStyle:"default"/g' "$TARGET_FILE"
        echo "✓ Native title bar enabled (titleBarStyle:default)"
    else
        echo "⚠ titleBarStyle pattern not found (may be different in this version)"
    fi
fi

# Apply to all JS files for broader coverage
find app.asar.contents -name "*.js" -type f 2>/dev/null | while read -r jsfile; do
    sed -i 's/frame:false/frame:true/g' "$jsfile" 2>/dev/null || true
    sed -i 's/frame:!1/frame:!0/g' "$jsfile" 2>/dev/null || true
    sed -i 's/titleBarStyle:"hidden",//g' "$jsfile" 2>/dev/null || true
    sed -i 's/,titleBarStyle:"hidden"//g' "$jsfile" 2>/dev/null || true
    sed -i 's/titleBarStyle:"hiddenInset",//g' "$jsfile" 2>/dev/null || true
    sed -i 's/titleBarOverlay:[^,}]*,//g' "$jsfile" 2>/dev/null || true
    sed -i 's/autoHideMenuBar:false/autoHideMenuBar:true/g' "$jsfile" 2>/dev/null || true
    sed -i 's/autoHideMenuBar:!1/autoHideMenuBar:!0/g' "$jsfile" 2>/dev/null || true
done

# =============================================================================
# FIX 3: Inject Linux fixes (v7 - grid collapse + element removal)
# =============================================================================
echo "🔧 Injecting Linux-specific fixes (v7 - grid collapse + element removal)..."
MAIN_ENTRY=$(grep -o '"main"[[:space:]]*:[[:space:]]*"[^"]*"' app.asar.contents/package.json 2>/dev/null | sed 's/"main"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' || true)
if [ -n "$MAIN_ENTRY" ] && [ -f "app.asar.contents/$MAIN_ENTRY" ]; then
    TEMP_FILE=$(mktemp)
    cat > "$TEMP_FILE" << 'INJECT_EOF'
// =============================================================================
// Linux Fixes - Injected by build script v7
// Strategy: Grid collapse + element removal (not just hiding)
// =============================================================================
(function() {
    if (process.platform !== 'linux') return;

    const { app, Menu, BrowserWindow } = require('electron');

    // Remove application menu
    const removeMenu = () => {
        try { Menu.setApplicationMenu(null); } catch(e) {}
    };
    removeMenu();
    app.on('ready', removeMenu);

    app.on('browser-window-created', (e, win) => {
        removeMenu();
        win.removeMenu();
        win.setMenu(null);
        win.setMenuBarVisibility(false);
        win.setAutoHideMenuBar(false);

        // Force relayout on window state changes
        const forceRelayout = () => {
            if (!win || win.isDestroyed()) return;
            try {
                const [width, height] = win.getSize();
                win.setSize(width, height + 1);
                setTimeout(() => {
                    if (win && !win.isDestroyed()) win.setSize(width, height);
                }, 50);
            } catch(e) {}
        };

        win.on('maximize', () => setTimeout(forceRelayout, 100));
        win.on('unmaximize', () => setTimeout(forceRelayout, 100));
        win.on('enter-full-screen', () => setTimeout(forceRelayout, 100));
        win.on('leave-full-screen', () => setTimeout(forceRelayout, 100));

        win.webContents.on('did-finish-load', () => {
            // Layer 1: CSS to collapse grid rows and reset spacing
            win.webContents.insertCSS(`
                /* v7: Universal spacing reset */
                html, body, #root, #app, body > div:first-child {
                    padding-top: 0 !important;
                    margin-top: 0 !important;
                    height: 100% !important;
                    width: 100% !important;
                }
                body {
                    position: fixed !important;
                    top: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    bottom: 0 !important;
                    overflow: hidden !important;
                }
                /* v7: Collapse grid rows - target containers that use grid layout */
                body > div:first-child {
                    display: grid !important;
                    grid-template-rows: 0 1fr !important;
                }
                /* v7: Hide first child (titlebar row) */
                body > div:first-child > div:first-child {
                    display: none !important;
                    height: 0 !important;
                    max-height: 0 !important;
                    overflow: hidden !important;
                }
                /* Fallback selectors for titlebar elements */
                [class*="titlebar" i], [class*="title-bar" i], [class*="drag-region" i],
                [class*="window-controls" i], [style*="-webkit-app-region: drag"],
                [style*="-webkit-app-region:drag"], [data-tauri-drag-region] {
                    display: none !important;
                    height: 0 !important;
                    visibility: hidden !important;
                }
            `).catch(() => {});

            // Layer 2: JavaScript to REMOVE titlebar elements (not just hide)
            win.webContents.executeJavaScript(`
                (function() {
                    'use strict';
                    const LOG = '[LinuxFix v7]';

                    // Check if element is likely a titlebar
                    const isTitlebar = (el) => {
                        if (!el || el.nodeType !== 1) return false;

                        // Method 1: Check -webkit-app-region (most reliable)
                        try {
                            const style = window.getComputedStyle(el);
                            if (style.getPropertyValue('-webkit-app-region') === 'drag') {
                                console.log(LOG, 'Found titlebar by -webkit-app-region:', el);
                                return true;
                            }
                        } catch(e) {}

                        // Method 2: Check class/id names
                        const className = (el.className?.toString?.() || '').toLowerCase();
                        const id = (el.id || '').toLowerCase();
                        if (className.includes('titlebar') || className.includes('title-bar') ||
                            className.includes('drag-region') || className.includes('window-control') ||
                            id.includes('titlebar') || id.includes('title-bar')) {
                            console.log(LOG, 'Found titlebar by class/id:', el);
                            return true;
                        }

                        // Method 3: Geometry check (element at top, bar-shaped)
                        try {
                            const rect = el.getBoundingClientRect();
                            if (rect.top >= 0 && rect.top < 10 &&
                                rect.height > 10 && rect.height <= 55 &&
                                rect.width >= window.innerWidth * 0.8) {
                                // Safety: skip if has significant content
                                const hasInputs = el.querySelector('input, textarea, [contenteditable]');
                                const textLen = (el.textContent || '').replace(/\\s+/g, '').length;
                                if (!hasInputs && textLen < 50) {
                                    console.log(LOG, 'Found titlebar by geometry:', el);
                                    return true;
                                }
                            }
                        } catch(e) {}

                        return false;
                    };

                    // Remove element from DOM completely
                    const removeElement = (el) => {
                        if (el && el.isConnected) {
                            console.log(LOG, 'Removing element:', el.tagName, el.className);
                            el.remove();
                        }
                    };

                    // Scan and remove titlebars
                    const scanAndRemove = () => {
                        // Check direct children of body
                        const bodyChildren = Array.from(document.body.children);
                        for (const child of bodyChildren) {
                            if (isTitlebar(child)) {
                                removeElement(child);
                                continue;
                            }
                            // Check grandchildren (first level inside root container)
                            const grandchildren = Array.from(child.children || []);
                            for (const gc of grandchildren) {
                                if (isTitlebar(gc)) {
                                    removeElement(gc);
                                }
                            }
                        }
                    };

                    // MutationObserver to catch dynamically added titlebars
                    const observer = new MutationObserver((mutations) => {
                        for (const m of mutations) {
                            for (const node of m.addedNodes) {
                                if (node.nodeType === 1) {
                                    if (isTitlebar(node)) {
                                        removeElement(node);
                                    } else if (node.querySelector) {
                                        node.querySelectorAll('*').forEach(child => {
                                            if (isTitlebar(child)) removeElement(child);
                                        });
                                    }
                                }
                            }
                        }
                    });

                    observer.observe(document.body, { childList: true, subtree: true });

                    // Run scans at different timings to catch React renders
                    scanAndRemove();
                    setTimeout(scanAndRemove, 100);
                    setTimeout(scanAndRemove, 500);
                    setTimeout(scanAndRemove, 1500);
                })();
            `).catch(() => {});
        });
    });

    // Intercept menu creation
    const originalSetMenu = Menu.setApplicationMenu;
    Menu.setApplicationMenu = function(menu) {
        return originalSetMenu.call(this, null);
    };
})();
// =============================================================================
INJECT_EOF
    cat "app.asar.contents/$MAIN_ENTRY" >> "$TEMP_FILE"
    mv "$TEMP_FILE" "app.asar.contents/$MAIN_ENTRY"
    echo "✓ Linux fixes injected (v7)"
fi

# =============================================================================
# FIX 4: CSS file patching (minimal - main fixes handled by JS injection)
# =============================================================================
echo "🔧 Patching CSS files (minimal v7)..."
# Only add essential grid collapse CSS to stylesheets as backup
find app.asar.contents -name "*.css" -type f 2>/dev/null | head -3 | while read -r cssfile; do
    TEMP_CSS=$(mktemp)
    cat > "$TEMP_CSS" << 'CSSEOF'
/* Linux v7: Grid collapse + titlebar removal */
body>div:first-child{display:grid!important;grid-template-rows:0 1fr!important;}
body>div:first-child>div:first-child{display:none!important;height:0!important;}
[class*="titlebar" i],[class*="drag-region" i]{display:none!important;height:0!important;}
CSSEOF
    cat "$cssfile" >> "$TEMP_CSS"
    mv "$TEMP_CSS" "$cssfile"
done
echo "✓ CSS patched (v7)"

# =============================================================================
# FIX 5: Origin validation bypass for file:// URLs
# =============================================================================
echo "🔧 Patching origin validation..."
find app.asar.contents -name "*.js" -type f 2>/dev/null | while read -r jsfile; do
    if grep -q "startsWith" "$jsfile" 2>/dev/null; then
        sed -i 's/\.startsWith("https:\/\/claude\.ai")/.startsWith("https:\/\/claude.ai")||e.startsWith("file:\/\/")/g' "$jsfile" 2>/dev/null || true
        sed -i 's/\.startsWith("https:\/\/")/.startsWith("https:\/\/")||e.startsWith("file:\/\/")/g' "$jsfile" 2>/dev/null || true
    fi
    sed -i 's/\["https:"\]/["https:","file:"]/g' "$jsfile" 2>/dev/null || true
    sed -i "s/\['https:'\]/['https:','file:']/g" "$jsfile" 2>/dev/null || true
done

MAIN_BUILD_JS=$(find app.asar.contents -path "*/.vite/build/*.js" -name "*.js" | head -1)
if [ -n "$MAIN_BUILD_JS" ] && [ -f "$MAIN_BUILD_JS" ]; then
    sed -i 's/throw new Error(`Incoming/console.warn(`[Linux] Incoming/g' "$MAIN_BUILD_JS" 2>/dev/null || true
fi
echo "✓ Origin validation patched"

# =============================================================================
# FIX 6: Native module stub for Google Sign-In
# =============================================================================
echo "🔧 Creating native module stub..."
mkdir -p app.asar.contents/node_modules/claude-native
cat > app.asar.contents/node_modules/claude-native/index.js << 'EOF'
const KeyboardKey = {
  Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40,
  CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250,
  End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262,
  DownArrow: 81, Delete: 79, Meta: 187
};
Object.freeze(KeyboardKey);
module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy Tray icons
mkdir -p app.asar.contents/resources
cp ../lib/net45/resources/Tray* app.asar.contents/resources/ 2>/dev/null || true

# Copy i18n
mkdir -p app.asar.contents/resources/i18n/
cp ../lib/net45/resources/*.json app.asar.contents/resources/i18n/ 2>/dev/null || true

# Repackage app.asar
npx asar pack app.asar.contents app.asar || { echo "asar pack failed"; exit 1; }

# Create native module in unpacked
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native"
cat > "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native/index.js" << 'EOF'
const KeyboardKey = {
  Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40,
  CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250,
  End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262,
  DownArrow: 81, Delete: 79, Meta: 187
};
Object.freeze(KeyboardKey);
module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},
  getIsMaximized: () => false,
  flashFrame: () => {},
  clearFlashFrame: () => {},
  showNotification: () => {},
  setProgressBar: () => {},
  clearProgressBar: () => {},
  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey
};
EOF

# Copy app files
cp app.asar "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r app.asar.unpacked "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Copy Electron
cp -r "$WORK_DIR/electron-dist"/* "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Create desktop entry
cat > "$INSTALL_DIR/share/applications/claude-desktop.desktop" << EOF
[Desktop Entry]
Name=Claude
Exec=claude-desktop %u
Icon=claude-desktop
Type=Application
Terminal=false
Categories=Office;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF

# =============================================================================
# LAUNCHER with Wayland/KDE compatibility
# =============================================================================
cat > "$INSTALL_DIR/bin/claude-desktop" << 'LAUNCHER_EOF'
#!/bin/bash
LOG_FILE="$HOME/.claude-desktop.log"

# Environment for Wayland/KDE compatibility
export GDK_BACKEND=x11
export GTK_USE_PORTAL=0
export QT_QPA_PLATFORM=xcb
export ELECTRON_DISABLE_SECURITY_WARNINGS=true

# Detect session type
SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"

# Find electron
ELECTRON_BIN="/usr/lib64/claude-desktop/electron"
APP_PATH="/usr/lib64/claude-desktop/app.asar"

# Flags for stability
FLAGS=(
    "--no-sandbox"
    "--ozone-platform=x11"
    "--disable-gpu-sandbox"
)

echo "[$(date)] Starting Claude Desktop v7 (session: $SESSION_TYPE)" >> "$LOG_FILE"

exec "$ELECTRON_BIN" "$APP_PATH" "${FLAGS[@]}" "$@" 2>> "$LOG_FILE"
LAUNCHER_EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"

# Create RPM spec file
cat > "$WORK_DIR/claude-desktop.spec" << EOF
Name:           claude-desktop
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Claude Desktop for Linux (Fedora 43+)
License:        Proprietary
URL:            https://www.anthropic.com
BuildArch:      ${ARCHITECTURE}
Requires:       nodejs >= 12.0.0

%description
Claude AI assistant desktop application.
Built with v7 grid-collapse titlebar fix for KDE/Wayland compatibility.

%install
mkdir -p %{buildroot}/usr/lib64/%{name}
mkdir -p %{buildroot}/usr/bin
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons

cp -r ${INSTALL_DIR}/lib/%{name}/* %{buildroot}/usr/lib64/%{name}/
cp -r ${INSTALL_DIR}/bin/* %{buildroot}/usr/bin/
cp -r ${INSTALL_DIR}/share/applications/* %{buildroot}/usr/share/applications/
cp -r ${INSTALL_DIR}/share/icons/* %{buildroot}/usr/share/icons/

%files
%{_bindir}/claude-desktop
%{_libdir}/%{name}
%{_datadir}/applications/claude-desktop.desktop
%{_datadir}/icons/hicolor/*/apps/claude-desktop.png

%post
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor || :
update-desktop-database %{_datadir}/applications || :

# Set sandbox permissions
if [ -f "/usr/lib64/claude-desktop/chrome-sandbox" ]; then
    chown root:root "/usr/lib64/claude-desktop/chrome-sandbox" || :
    chmod 4755 "/usr/lib64/claude-desktop/chrome-sandbox" || :
fi

%changelog
* $(date '+%a %b %d %Y') ${MAINTAINER} ${VERSION}-1
- v7: Grid collapse + element removal titlebar fix for Fedora 43
EOF

# Build RPM package
echo "📦 Building RPM package..."
mkdir -p "${WORK_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

RPM_FILE="$(pwd)/${ARCHITECTURE}/claude-desktop-${VERSION}-1${DISTRIBUTION}.$(uname -m).rpm"
if rpmbuild -bb \
    --define "_topdir ${WORK_DIR}" \
    --define "_rpmdir $(pwd)" \
    "${WORK_DIR}/claude-desktop.spec"; then
    echo "============================================================================"
    echo "✓ RPM package built successfully!"
    echo "============================================================================"
    echo "Install with: sudo dnf install $RPM_FILE"
    echo "============================================================================"
else
    echo "RPM build failed"
    exit 1
fi
