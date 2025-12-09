#!/bin/bash

# Nama aplikasi (sesuai dengan nama .app)
APP_NAME="Hlaprint"
# Path ke aplikasi yang sudah di-build
APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
# Nama output DMG
DMG_NAME="${APP_NAME}_Installer.dmg"
# Path ke folder sementara untuk konten DMG
TEMP_DMG_DIR="dmg_contents"

# Cek apakah aplikasi ada
if [ ! -d "$APP_PATH" ]; then
  echo "❌ Error: Aplikasi tidak ditemukan di $APP_PATH"
  echo "   Jalankan dulu: flutter build macos --release"
  exit 1
fi

# Cek apakah create-dmg terinstall
if ! command -v create-dmg &> /dev/null; then
  echo "❌ Error: create-dmg tidak terinstall"
  echo "   Install dulu: brew install create-dmg"
  exit 1
fi

# Cek apakah logo.icns ada (optional)
VOLICON_OPTION=""
if [ -f "logo.icns" ]; then
  VOLICON_OPTION="--volicon logo.icns"
  echo "✅ Logo ditemukan: logo.icns"
else
  echo "⚠️  Logo tidak ditemukan, lanjut tanpa logo.icns"
fi

# Buat folder sementara
mkdir -p "$TEMP_DMG_DIR"

echo "📦 Menyalin aplikasi..."
# Salin aplikasi ke folder sementara
cp -R "$APP_PATH" "$TEMP_DMG_DIR/"

# Buat alias ke folder Applications
echo "🔗 Membuat shortcut Applications..."
ln -s /Applications "$TEMP_DMG_DIR/Applications"

# Hapus file DMG jika sudah ada
if [ -f "$DMG_NAME" ]; then
  echo "🗑️  Menghapus DMG lama..."
  rm "$DMG_NAME"
fi

echo "🛠️  Membuat DMG..."

# Bangun command create-dmg
CMD="create-dmg \
  --volname \"$APP_NAME\" \
  $VOLICON_OPTION \
  --window-pos 200 120 \
  --window-size 600 300 \
  --icon-size 100 \
  --icon \"$APP_NAME.app\" 100 100 \
  --icon \"Applications\" 400 100 \
  --hide-extension \"$APP_NAME.app\" \
  --app-drop-link 400 100 \
  --no-internet-enable \
  \"$DMG_NAME\" \
  \"$TEMP_DMG_DIR/\""

# Debug: tampilkan command
echo "🔧 Command: $CMD"

# Eksekusi command
eval $CMD

# Hapus folder sementara
echo "🧹 Membersihkan folder sementara..."
rm -rf "$TEMP_DMG_DIR"

echo ""
echo "✅ Selesai! DMG berhasil dibuat:"
echo "📁 $DMG_NAME"
echo ""
echo "📋 Langkah instalasi:"
echo "1. Double-click $DMG_NAME"
echo "2. Drag $APP_NAME.app ke folder Applications"
echo "3. Jika ada warning, Control+Click → Open"