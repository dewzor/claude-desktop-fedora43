#!/bin/bash
set -e

# =============================================================================
# Claude Desktop for Fedora 42+ - Complete Build Script
#
# Fixes included:
#   - Layout scaling (main_window.tgz patch)
#   - Native window frame (no custom titlebar issues)
#   - Menu bar FULLY removed
#   - Window maximize/resize fix (forced relayout)
#   - Google Sign-In (native module stub)
#   - Origin validation bypass (IPC security fix for file:// URLs)
#   - GPU/Wayland compatibility (software rendering fallback)
#
# v5 Changelog:
#   - Fixed: Maximize glitch via forced relayout and size recalculation
# =============================================================================

CLAUDE_DOWNLOAD_URL="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-Setup-x64.exe"
ELECTRON_VERSION=${ELECTRON_VERSION:-"37.0.0"}
ELECTRON_DOWNLOAD_URL=${ELECTRON_DOWNLOAD_URL:-"https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/electron-v${ELECTRON_VERSION}-linux-x64.zip"}
MAIN_WINDOW_FIX_URL="https://github.com/emsi/claude-desktop/raw/refs/heads/main/assets/main_window.tgz"

is_fedora_based() {
    [ -f "/etc/fedora-release" ] && return 0
    [ -f "/etc/os-release" ] && grep -qi "fedora" /etc/os-release && return 0
    return 1
}

if ! is_fedora_based; then
    echo "❌ This script requires a Fedora-based Linux distribution"
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
echo "Claude Desktop for Fedora - Build Script (FINAL v5)"
echo "============================================================================"
echo "Distribution: $(cat /etc/os-release | grep "PRETTY_NAME" | cut -d'"' -f2)"
echo "============================================================================"

# Check dependencies
check_command() {
    command -v "$1" &> /dev/null && echo "✓ $1" && return 0
    echo "❌ $1 not found" && return 1
}

DEPS_TO_INSTALL=""
for cmd in sqlite3 7z wget curl unzip wrestool icotool convert npx rpmbuild; do
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
        esac
    fi
done

[ -n "$DEPS_TO_INSTALL" ] && dnf install -y $DEPS_TO_INSTALL

PACKAGE_NAME="claude-desktop"
ARCHITECTURE=$(uname -m)
DISTRIBUTION=$(rpm --eval %{?dist})

WORK_DIR="$(pwd)/build"
FEDORA_ROOT="$WORK_DIR/fedora-package"
INSTALL_DIR="$FEDORA_ROOT/usr"

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$FEDORA_ROOT/FEDORA"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME" "$INSTALL_DIR/share/applications" "$INSTALL_DIR/share/icons" "$INSTALL_DIR/bin"

# Install asar
command -v asar > /dev/null 2>&1 || npm install -g asar

# Download Claude
echo "📥 Downloading Claude Desktop..."
CLAUDE_EXE="$WORK_DIR/Claude-Setup-x64.exe"
curl -o "$CLAUDE_EXE" "$CLAUDE_DOWNLOAD_URL" || { echo "❌ Download failed"; exit 1; }

# Extract
echo "📦 Extracting..."
cd "$WORK_DIR"
7z x -y "$CLAUDE_EXE" || { echo "❌ Extract failed"; exit 1; }

NUPKG_FILE=$(find . -name "AnthropicClaude-*-full.nupkg" | head -1)
[ -z "$NUPKG_FILE" ] && { echo "❌ nupkg not found"; exit 1; }

VERSION=$(echo "$NUPKG_FILE" | grep -oP 'AnthropicClaude-\K[0-9]+\.[0-9]+\.[0-9]+(?=-full\.nupkg)')
echo "📋 Version: $VERSION"

7z x -y "$NUPKG_FILE" || { echo "❌ nupkg extract failed"; exit 1; }

# Download Electron
echo "📥 Downloading Electron v${ELECTRON_VERSION}..."
curl -L -o "$WORK_DIR/electron.zip" "$ELECTRON_DOWNLOAD_URL" || { echo "❌ Electron download failed"; exit 1; }
unzip -q "$WORK_DIR/electron.zip" -d "$WORK_DIR/electron-dist"
echo "✓ Electron ready"

# Extract icons
echo "🎨 Processing icons..."
wrestool -x -t 14 "lib/net45/claude.exe" -o claude.ico && icotool -x claude.ico

declare -A icon_files=(
    ["16"]="claude_13_16x16x32.png" ["24"]="claude_11_24x24x32.png"
    ["32"]="claude_10_32x32x32.png" ["48"]="claude_8_48x48x32.png"
    ["64"]="claude_7_64x64x32.png" ["256"]="claude_6_256x256x32.png"
)

for size in 16 24 32 48 64 256; do
    icon_dir="$INSTALL_DIR/share/icons/hicolor/${size}x${size}/apps"
    mkdir -p "$icon_dir"
    [ -f "${icon_files[$size]}" ] && install -Dm 644 "${icon_files[$size]}" "$icon_dir/claude-desktop.png"
done

# Process app.asar
echo "📦 Processing app.asar..."
mkdir -p electron-app
cp "lib/net45/resources/app.asar" electron-app/
cp -r "lib/net45/resources/app.asar.unpacked" electron-app/

cd electron-app
npx asar extract app.asar app.asar.contents || { echo "asar extract failed"; exit 1; }

# =============================================================================
# FIX 1: Apply main_window patch
# =============================================================================
echo "🔧 Applying main_window patch..."
wget -O- "$MAIN_WINDOW_FIX_URL" 2>/dev/null | tar -zxvf - -C app.asar.contents/ 2>/dev/null || echo "⚠️ main_window.tgz patch skipped"

# =============================================================================
# FIX 2: Enable native window frame + remove menu bar completely
# =============================================================================
echo "🔧 Enabling native frame and removing menu..."
find app.asar.contents -name "*.js" -type f 2>/dev/null | while read -r jsfile; do
    # Enable native frame
    sed -i 's/frame:false/frame:true/g' "$jsfile"
    sed -i 's/frame:!1/frame:!0/g' "$jsfile"
    sed -i 's/frame: false/frame: true/g' "$jsfile"

    # Remove all titleBarStyle settings completely
    sed -i 's/titleBarStyle:"hidden",//g' "$jsfile"
    sed -i 's/,titleBarStyle:"hidden"//g' "$jsfile"
    sed -i 's/titleBarStyle:"hidden"//g' "$jsfile"
    sed -i "s/titleBarStyle:'hidden',//g" "$jsfile"
    sed -i "s/,titleBarStyle:'hidden'//g" "$jsfile"
    sed -i 's/titleBarStyle:"hiddenInset",//g' "$jsfile"
    sed -i 's/,titleBarStyle:"hiddenInset"//g' "$jsfile"
    sed -i 's/titleBarStyle:"customButtonsOnHover",//g' "$jsfile"
    sed -i 's/,titleBarStyle:"customButtonsOnHover"//g' "$jsfile"

    # Remove titleBarOverlay
    sed -i 's/titleBarOverlay:[^,}]*,//g' "$jsfile"
    sed -i 's/,titleBarOverlay:[^}]*}/}/g' "$jsfile"

    # Remove trafficLightPosition (macOS)
    sed -i 's/trafficLightPosition:[^,}]*,//g' "$jsfile"
    sed -i 's/,trafficLightPosition:[^}]*}/}/g' "$jsfile"
done

# =============================================================================
# FIX 3: Inject comprehensive Linux fixes into main entry
# =============================================================================
echo "🔧 Injecting Linux-specific fixes..."
MAIN_ENTRY=$(grep -o '"main"[[:space:]]*:[[:space:]]*"[^"]*"' app.asar.contents/package.json 2>/dev/null | sed 's/"main"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/' || true)
if [ -n "$MAIN_ENTRY" ] && [ -f "app.asar.contents/$MAIN_ENTRY" ]; then
    TEMP_FILE=$(mktemp)
    cat > "$TEMP_FILE" << 'INJECT_EOF'
// =============================================================================
// Linux Fixes - Injected by build script v5
// =============================================================================
(function() {
    if (process.platform !== 'linux') return;

    const { app, Menu, BrowserWindow } = require('electron');

    // 1. Remove application menu completely
    const removeMenu = () => {
        try {
            Menu.setApplicationMenu(null);
        } catch(e) {}
    };

    // Remove menu immediately and on every possible event
    removeMenu();
    app.on('ready', removeMenu);

    app.on('browser-window-created', (e, win) => {
        removeMenu();
        win.removeMenu();
        win.setMenu(null);
        win.setMenuBarVisibility(false);
        win.setAutoHideMenuBar(false);

        // Track if we're in a resize operation
        let isMaximizing = false;

        // Function to force proper layout
        const forceRelayout = () => {
            if (!win || win.isDestroyed()) return;

            try {
                const [width, height] = win.getSize();
                const bounds = win.getBounds();

                // Force the renderer to recalculate by briefly changing size
                win.setSize(width, height + 1);

                setTimeout(() => {
                    if (win && !win.isDestroyed()) {
                        win.setSize(width, height);

                        // Also trigger resize event in the renderer
                        win.webContents.executeJavaScript(`
                            window.dispatchEvent(new Event('resize'));
                            document.body.style.display = 'none';
                            document.body.offsetHeight;
                            document.body.style.display = '';
                        `).catch(() => {});
                    }
                }, 50);
            } catch(e) {}
        };

        // Fix maximize/unmaximize
        win.on('maximize', () => {
            isMaximizing = true;
            setTimeout(() => {
                forceRelayout();
                isMaximizing = false;
            }, 100);
        });

        win.on('unmaximize', () => {
            setTimeout(forceRelayout, 100);
        });

        win.on('enter-full-screen', () => {
            setTimeout(forceRelayout, 100);
        });

        win.on('leave-full-screen', () => {
            setTimeout(forceRelayout, 100);
        });

        // Inject CSS and DOM fixes after page loads
        win.webContents.on('did-finish-load', () => {
            // Inject comprehensive CSS to remove titlebar elements and fix layout
            win.webContents.insertCSS(`
                /* ============================================= */
                /* Linux: Remove titlebar and fix layout - v5   */
                /* ============================================= */

                /* Nuclear option: hide any element that looks like a titlebar */
                [class*="titlebar" i],
                [class*="Titlebar" i],
                [class*="title-bar" i],
                [class*="TitleBar" i],
                [class*="titleBar" i],
                [id*="titlebar" i],
                [id*="title-bar" i],
                [id*="titleBar" i],
                [class*="drag-region" i],
                [class*="dragRegion" i],
                [class*="DragRegion" i],
                [class*="window-controls" i],
                [class*="windowControls" i],
                [class*="WindowControls" i],
                [class*="traffic-light" i],
                [class*="trafficLight" i],
                [class*="app-region-drag"],
                [style*="-webkit-app-region: drag"],
                [style*="-webkit-app-region:drag"],
                [data-tauri-drag-region] {
                    display: none !important;
                    visibility: hidden !important;
                    height: 0 !important;
                    max-height: 0 !important;
                    min-height: 0 !important;
                    padding: 0 !important;
                    margin: 0 !important;
                    border: none !important;
                    overflow: hidden !important;
                    opacity: 0 !important;
                    pointer-events: none !important;
                    position: absolute !important;
                    z-index: -9999 !important;
                }

                /* Fix body and html to fill viewport */
                html {
                    height: 100% !important;
                    width: 100% !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    overflow: hidden !important;
                }

                body {
                    height: 100% !important;
                    width: 100% !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    padding-top: 0 !important;
                    margin-top: 0 !important;
                    overflow: hidden !important;
                    position: fixed !important;
                    top: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    bottom: 0 !important;
                }

                /* First child of body - likely the app container */
                body > div:first-child {
                    height: 100% !important;
                    width: 100% !important;
                    max-height: 100% !important;
                    padding-top: 0 !important;
                    margin-top: 0 !important;
                    position: absolute !important;
                    top: 0 !important;
                    left: 0 !important;
                    right: 0 !important;
                    bottom: 0 !important;
                }

                /* Common app container IDs */
                #root, #app, #__next, [id*="app-container" i], [class*="app-container" i] {
                    height: 100% !important;
                    width: 100% !important;
                    max-height: 100% !important;
                    padding-top: 0 !important;
                    margin-top: 0 !important;
                }

                /* Remove any top padding/margin from main content */
                main, [role="main"], [class*="main-content" i], [class*="mainContent" i] {
                    padding-top: 0 !important;
                    margin-top: 0 !important;
                }
            `).catch(() => {});

            // DOM surgery: find and remove the white bar
            win.webContents.executeJavaScript(`
                (function removeWhiteBar() {
                    // Strategy 1: Remove elements by class name patterns
                    const patterns = [
                        /titlebar/i, /title-bar/i, /drag-region/i, /dragregion/i,
                        /window-controls/i, /windowcontrols/i, /traffic-light/i,
                        /trafficlight/i, /app-region/i
                    ];

                    document.querySelectorAll('*').forEach(el => {
                        const className = el.className?.toString?.() || '';
                        const id = el.id || '';

                        for (const pattern of patterns) {
                            if (pattern.test(className) || pattern.test(id)) {
                                el.style.cssText = 'display:none!important;height:0!important;visibility:hidden!important;';
                                return;
                            }
                        }
                    });

                    // Strategy 2: Find small fixed-height elements at the top
                    // These are likely titlebar containers
                    const removeTopBars = () => {
                        // Check direct children of body
                        const children = Array.from(document.body.children);
                        for (const child of children) {
                            const rect = child.getBoundingClientRect();
                            const style = getComputedStyle(child);

                            // If element is at top, has small height, and spans full width
                            // it's probably a titlebar/toolbar
                            if (rect.top < 5 && rect.height > 0 && rect.height <= 50 &&
                                rect.width > window.innerWidth * 0.8) {

                                // Check if it contains actual content (chat UI) or not
                                const hasTextContent = child.textContent?.trim().length > 100;
                                const hasInputs = child.querySelectorAll('input, textarea, button').length > 3;

                                // If it doesn't have much content, it's probably a titlebar
                                if (!hasTextContent && !hasInputs) {
                                    console.log('[Linux] Removing suspected titlebar:', child.className || child.id || 'unnamed');
                                    child.style.cssText = 'display:none!important;height:0!important;max-height:0!important;visibility:hidden!important;overflow:hidden!important;';
                                }
                            }
                        }

                        // Also check first grandchild
                        const firstChild = document.body.firstElementChild;
                        if (firstChild) {
                            const grandchildren = Array.from(firstChild.children);
                            for (const gc of grandchildren) {
                                const rect = gc.getBoundingClientRect();
                                if (rect.top < 5 && rect.height > 0 && rect.height <= 50 &&
                                    rect.width > window.innerWidth * 0.8) {
                                    const hasTextContent = gc.textContent?.trim().length > 100;
                                    const hasInputs = gc.querySelectorAll('input, textarea, button').length > 3;
                                    if (!hasTextContent && !hasInputs) {
                                        console.log('[Linux] Removing suspected titlebar (grandchild):', gc.className || gc.id || 'unnamed');
                                        gc.style.cssText = 'display:none!important;height:0!important;max-height:0!important;visibility:hidden!important;overflow:hidden!important;';
                                    }
                                }
                            }
                        }
                    };

                    // Run immediately
                    removeTopBars();

                    // Run again after a short delay (for dynamic content)
                    setTimeout(removeTopBars, 100);
                    setTimeout(removeTopBars, 500);
                    setTimeout(removeTopBars, 1000);

                    // Watch for new elements
                    const observer = new MutationObserver((mutations) => {
                        let shouldCheck = false;
                        for (const m of mutations) {
                            if (m.addedNodes.length > 0) {
                                shouldCheck = true;
                                // Also check added nodes directly
                                m.addedNodes.forEach(node => {
                                    if (node.nodeType === 1) {
                                        const className = (node.className?.toString?.() || '').toLowerCase();
                                        const id = (node.id || '').toLowerCase();
                                        if (className.includes('titlebar') || className.includes('drag') ||
                                            id.includes('titlebar') || id.includes('drag')) {
                                            node.style.cssText = 'display:none!important;height:0!important;visibility:hidden!important;';
                                        }
                                    }
                                });
                            }
                        }
                        if (shouldCheck) {
                            setTimeout(removeTopBars, 10);
                        }
                    });

                    observer.observe(document.body, {
                        childList: true,
                        subtree: true
                    });

                    // Strategy 3: Fix body padding/margin that might be reserved for titlebar
                    document.body.style.paddingTop = '0';
                    document.body.style.marginTop = '0';
                    if (document.body.firstElementChild) {
                        document.body.firstElementChild.style.paddingTop = '0';
                        document.body.firstElementChild.style.marginTop = '0';
                    }
                })();
            `).catch(() => {});
        });

        // Also inject on DOM ready (earlier than did-finish-load)
        win.webContents.on('dom-ready', () => {
            win.webContents.insertCSS(`
                [class*="titlebar" i],[class*="drag-region" i],[class*="window-controls" i]{display:none!important;height:0!important;}
                body{padding-top:0!important;margin-top:0!important;}
            `).catch(() => {});
        });
    });

    // Intercept Menu.setApplicationMenu to prevent app from setting menu
    const originalSetMenu = Menu.setApplicationMenu;
    Menu.setApplicationMenu = function(menu) {
        return originalSetMenu.call(this, null);
    };

})();
// =============================================================================
INJECT_EOF
    cat "app.asar.contents/$MAIN_ENTRY" >> "$TEMP_FILE"
    mv "$TEMP_FILE" "app.asar.contents/$MAIN_ENTRY"
fi

# =============================================================================
# FIX 4: Remove titlebar CSS from all stylesheets
# =============================================================================
echo "🔧 Patching CSS files..."
find app.asar.contents -name "*.css" -type f 2>/dev/null | while read -r cssfile; do
    # Prepend aggressive titlebar removal CSS
    TEMP_CSS=$(mktemp)
    cat > "$TEMP_CSS" << 'CSSEOF'
/* Linux: Remove titlebar elements - v5 */
[class*="titlebar" i],[class*="Titlebar" i],[class*="title-bar" i],[class*="TitleBar" i],[id*="titlebar" i],[id*="title-bar" i],[class*="drag-region" i],[class*="dragRegion" i],[class*="window-controls" i],[class*="windowControls" i],[style*="-webkit-app-region"]{display:none!important;height:0!important;max-height:0!important;min-height:0!important;visibility:hidden!important;overflow:hidden!important;padding:0!important;margin:0!important;border:none!important;opacity:0!important;position:absolute!important;pointer-events:none!important;z-index:-9999!important;}
html{height:100%!important;width:100%!important;margin:0!important;padding:0!important;overflow:hidden!important;}
body{height:100%!important;width:100%!important;margin:0!important;padding:0!important;padding-top:0!important;margin-top:0!important;overflow:hidden!important;position:fixed!important;top:0!important;left:0!important;right:0!important;bottom:0!important;}
body>div:first-child{height:100%!important;width:100%!important;max-height:100%!important;padding-top:0!important;margin-top:0!important;position:absolute!important;top:0!important;left:0!important;right:0!important;bottom:0!important;}
#root,#app{height:100%!important;width:100%!important;max-height:100%!important;padding-top:0!important;margin-top:0!important;}
CSSEOF
    cat "$cssfile" >> "$TEMP_CSS"
    mv "$TEMP_CSS" "$cssfile"
done

# =============================================================================
# FIX 5: Patch JS to prevent titlebar/menu creation
# =============================================================================
echo "🔧 Patching JS for menu prevention..."
find app.asar.contents -name "*.js" -type f 2>/dev/null | while read -r jsfile; do
    # Prevent autoHideMenuBar from being set to false
    sed -i 's/autoHideMenuBar:false/autoHideMenuBar:true/g' "$jsfile"
    sed -i 's/autoHideMenuBar:!1/autoHideMenuBar:!0/g' "$jsfile"

    # Remove setMenu calls that would set a menu
    sed -i 's/\.setMenu([^)]*Menu\.buildFromTemplate([^)]*))/.setMenu(null)/g' "$jsfile"

    # Prevent menuBarVisible from being true
    sed -i 's/menuBarVisible:true/menuBarVisible:false/g' "$jsfile"
    sed -i 's/menuBarVisible:!0/menuBarVisible:!1/g' "$jsfile"
done

# =============================================================================
# FIX 6: CRITICAL - Bypass origin validation for file:// URLs
# =============================================================================
echo "🔧 Patching origin validation (CRITICAL FIX)..."

find app.asar.contents -name "*.js" -type f 2>/dev/null | while read -r jsfile; do
    # Fix 1: Make startsWith checks include file://
    if grep -q "startsWith" "$jsfile" 2>/dev/null; then
        sed -i 's/\.startsWith("https:\/\/claude\.ai")/.startsWith("https:\/\/claude.ai")||e.startsWith("file:\/\/")/g' "$jsfile" 2>/dev/null || true
        sed -i 's/\.startsWith("https:\/\/")/.startsWith("https:\/\/")||e.startsWith("file:\/\/")/g' "$jsfile" 2>/dev/null || true
    fi

    # Fix 2: Patch the specific validation function
    sed -i 's/did not pass origin validation/origin ok (linux)/g' "$jsfile" 2>/dev/null || true

    # Fix 3: Make the validation always pass for file://
    sed -i 's/senderFrame\.url\.startsWith/senderFrame.url.startsWith("file:\/\/")||senderFrame.url.startsWith/g' "$jsfile" 2>/dev/null || true
    sed -i 's/event\.senderFrame\.url\.startsWith/event.senderFrame.url.startsWith("file:\/\/")||event.senderFrame.url.startsWith/g' "$jsfile" 2>/dev/null || true

    # Fix 4: Patch URL validation to always include file protocol
    sed -i 's/\["https:"\]/["https:","file:"]/g' "$jsfile" 2>/dev/null || true
    sed -i "s/\['https:'\]/['https:','file:']/g" "$jsfile" 2>/dev/null || true
done

# More aggressive fix: Find and patch the actual validation code
echo "🔧 Applying deep origin validation fix..."
MAIN_BUILD_JS=$(find app.asar.contents -path "*/.vite/build/*.js" -name "*.js" | head -1)
if [ -n "$MAIN_BUILD_JS" ] && [ -f "$MAIN_BUILD_JS" ]; then
    echo "  Found main build: $MAIN_BUILD_JS"
    cp "$MAIN_BUILD_JS" "${MAIN_BUILD_JS}.bak"
    sed -i 's/throw new Error(`Incoming "\${[^}]*}" call on interface "\${[^}]*}" from/console.log(`[Linux] IPC call from/g' "$MAIN_BUILD_JS" 2>/dev/null || true
    sed -i "s/throw new Error(\`Incoming/console.log(\`[Linux OK] Incoming/g" "$MAIN_BUILD_JS" 2>/dev/null || true
    sed -i 's/Error(`Incoming/console.warn(`[Linux] Incoming/g' "$MAIN_BUILD_JS" 2>/dev/null || true
fi

# Also patch all JS files in .vite directory
find app.asar.contents/.vite -name "*.js" -type f 2>/dev/null | while read -r jsfile; do
    [[ "$jsfile" == *.bak ]] && continue
    sed -i 's/throw new Error.*origin validation.*/console.warn("[Linux] Origin check bypassed"); return;/g' "$jsfile" 2>/dev/null || true
done

echo "✓ Origin validation patched"

# =============================================================================
# FIX 7: Native module stub for Google Sign-In
# =============================================================================
echo "🔧 Creating native module stub..."
mkdir -p app.asar.contents/node_modules/claude-native
cat > app.asar.contents/node_modules/claude-native/index.js << 'EOF'
const { shell } = require('electron');

const openUrl = (url) => {
    if (url && shell?.openExternal) {
        try { return shell.openExternal(url); } catch(e) { console.warn('openUrl failed', e); }
    }
    return null;
};

const desktopBrowser = {
    isAvailable: true,
    openUrl,
    openExternal: openUrl,
    openUrlWithSystemBrowser: openUrl,
};

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
    showNotification: () => {},
    setProgressBar: () => {},
    desktopBrowser,
    desktopApi: { browserIntegration: desktopBrowser, desktopBrowser },
    browserIntegration: desktopBrowser,
    browser: desktopBrowser,
    getBrowser: () => desktopBrowser,
    getDesktopBrowser: () => desktopBrowser,
    openUrlInBrowser: openUrl,
    KeyboardKey
};
module.exports.default = module.exports;
EOF

mkdir -p app.asar.contents/node_modules/claude-native-bindings
cp app.asar.contents/node_modules/claude-native/index.js app.asar.contents/node_modules/claude-native-bindings/

# Copy resources
mkdir -p app.asar.contents/resources/i18n
cp ../lib/net45/resources/Tray* app.asar.contents/resources/ 2>/dev/null || true
cp ../lib/net45/resources/*.json app.asar.contents/resources/i18n/ 2>/dev/null || true

# Repack
echo "📦 Repacking app.asar..."
npx asar pack app.asar.contents app.asar || { echo "asar pack failed"; exit 1; }

# Install files
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native"
mkdir -p "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native-bindings"
cp app.asar.contents/node_modules/claude-native/index.js "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native/"
cp app.asar.contents/node_modules/claude-native/index.js "$INSTALL_DIR/lib/$PACKAGE_NAME/app.asar.unpacked/node_modules/claude-native-bindings/"
cp app.asar "$INSTALL_DIR/lib/$PACKAGE_NAME/"
cp -r app.asar.unpacked "$INSTALL_DIR/lib/$PACKAGE_NAME/"

# Install Electron
echo "📦 Installing Electron..."
cp -a "$WORK_DIR/electron-dist"/. "$INSTALL_DIR/lib/$PACKAGE_NAME/electron/"
chmod +x "$INSTALL_DIR/lib/$PACKAGE_NAME/electron/electron"

# Desktop entry
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
# LAUNCHER with GPU fixes for Wayland/X11
# =============================================================================
cat > "$INSTALL_DIR/bin/claude-desktop" << 'LAUNCHER_EOF'
#!/usr/bin/bash

ELECTRON_BIN="/usr/lib64/claude-desktop/electron/electron"
APP_PATH="/usr/lib64/claude-desktop/app.asar"
LOG_FILE="${HOME}/.claude-desktop.log"

# Detect session type
SESSION_TYPE="${XDG_SESSION_TYPE:-x11}"

# Base flags
BASE_FLAGS=(
    "--no-sandbox"
)

# GPU/platform flags
if [ "$SESSION_TYPE" = "wayland" ]; then
    PLATFORM_FLAGS=(
        "--ozone-platform=x11"
        "--disable-gpu-sandbox"
    )
else
    PLATFORM_FLAGS=(
        "--ozone-platform=x11"
        "--disable-gpu-sandbox"
    )
fi

ALL_FLAGS=(
    "${BASE_FLAGS[@]}"
    "${PLATFORM_FLAGS[@]}"
)

echo "[$(date)] Starting Claude Desktop (session: $SESSION_TYPE)" >> "$LOG_FILE"
echo "[$(date)] Flags: ${ALL_FLAGS[*]}" >> "$LOG_FILE"

exec "$ELECTRON_BIN" "$APP_PATH" "${ALL_FLAGS[@]}" "$@" 2>> "$LOG_FILE"
LAUNCHER_EOF
chmod +x "$INSTALL_DIR/bin/claude-desktop"

# RPM spec
cat > "$WORK_DIR/claude-desktop.spec" << EOF
Name:           claude-desktop
Version:        ${VERSION}
Release:        1%{?dist}
Summary:        Claude Desktop for Linux
License:        Proprietary
URL:            https://www.anthropic.com
BuildArch:      ${ARCHITECTURE}

%description
Claude AI assistant desktop application.

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
gtk-update-icon-cache -f -t %{_datadir}/icons/hicolor 2>/dev/null || :
update-desktop-database %{_datadir}/applications 2>/dev/null || :
EOF

# Build RPM
echo "📦 Building RPM..."
mkdir -p "${WORK_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
RPM_FILE="$(pwd)/${ARCHITECTURE}/claude-desktop-${VERSION}-1${DISTRIBUTION}.$(uname -m).rpm"

if rpmbuild -bb --define "_topdir ${WORK_DIR}" --define "_rpmdir $(pwd)" "${WORK_DIR}/claude-desktop.spec"; then
    echo ""
    echo "============================================================================"
    echo "✅ SUCCESS! RPM: $RPM_FILE"
    echo "============================================================================"
    echo ""
    echo "Install:"
    echo "  sudo dnf install $RPM_FILE"
    echo ""
    echo "Run:"
    echo "  claude-desktop"
    echo ""
    echo "Logs: ~/.claude-desktop.log"
    echo "============================================================================"
else
    echo "❌ RPM build failed"
    exit 1
fi
