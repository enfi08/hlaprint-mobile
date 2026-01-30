#!/bin/bash

# Nama aplikasi (sesuai dengan nama .app)
APP_NAME="Hlaprint"
# Path ke aplikasi yang sudah di-build
APP_PATH="build/macos/Build/Products/Release/${APP_NAME}.app"
# Nama output DMG
DMG_NAME="${APP_NAME}_Installer_$(date +%Y%m%d_%H%M%S).dmg"
# Path ke folder sementara untuk konten DMG
TEMP_DMG_DIR="dmg_contents"

echo "🛠️  Membuat DMG untuk $APP_NAME"
echo "================================"

# Cek apakah aplikasi ada
if [ ! -d "$APP_PATH" ]; then
  echo "❌ Error: Aplikasi tidak ditemukan di $APP_PATH"
  echo "   Jalankan dulu: flutter build macos --release"
  exit 1
fi

echo "✅ Aplikasi ditemukan: $(basename "$APP_PATH")"

# Cek apakah create-dmg terinstall
if ! command -v create-dmg &> /dev/null; then
  echo "❌ Error: create-dmg tidak terinstall"
  echo "   Install dulu: brew install create-dmg"
  exit 1
fi

echo "✅ create-dmg terinstall"

# Cek apakah logo.icns ada (optional)
VOLICON_OPTION=""
if [ -f "logo.icns" ]; then
  VOLICON_OPTION="--volicon logo.icns"
  echo "✅ Logo ditemukan: logo.icns"
else
  echo "ℹ️  Logo tidak ditemukan, lanjut tanpa logo.icns"
fi

# Hapus folder sementara jika ada
if [ -d "$TEMP_DMG_DIR" ]; then
  echo "🧹 Membersihkan folder sementara lama..."
  rm -rf "$TEMP_DMG_DIR"
fi

# Buat folder sementara
mkdir -p "$TEMP_DMG_DIR"

echo "📦 Menyalin aplikasi..."
# Gunakan rsync untuk preserve symlinks dan permission
rsync -a "$APP_PATH/" "$TEMP_DMG_DIR/${APP_NAME}.app/"

# Hapus semua extended attributes
echo "🧹 Membersihkan extended attributes..."
xattr -cr "$TEMP_DMG_DIR/${APP_NAME}.app"

# Buat alias ke folder Applications
echo "🔗 Membuat shortcut Applications..."
ln -s /Applications "$TEMP_DMG_DIR/Applications"

# Hapus file DMG jika sudah ada
if [ -f "$DMG_NAME" ]; then
  echo "🗑️  Menghapus DMG lama..."
  rm "$DMG_NAME"
fi

echo "🛠️  Membuat DMG..."

CMD_ARGS=(
  --volname "$APP_NAME"
  --window-pos 200 120
  --window-size 600 300
  --icon-size 100
  --icon "$APP_NAME.app" 100 100
  --icon "Applications" 400 100
  --hide-extension "$APP_NAME.app"
  --app-drop-link 400 100
  --no-internet-enable
  --format UDZO
  --hfs-imaging-format UDZO
  --skip-jenkins
)

# Tambahkan volicon hanya jika ada
if [ -f "logo.icns" ]; then
  CMD_ARGS+=(--volicon "logo.icns")
fi

CMD_ARGS+=("$DMG_NAME" "$TEMP_DMG_DIR/")

echo "🔧 Executing: create-dmg" "${CMD_ARGS[@]}"

# Eksekusi langsung tanpa eval
if ! create-dmg "${CMD_ARGS[@]}"; then
  echo ""
  echo "⚠️  create-dmg gagal, mencoba metode alternatif..."
  
  # Fallback ke hdiutil langsung
  echo "🔄 Menggunakan hdiutil langsung..."
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$TEMP_DMG_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -fs HFS+J \
    "$DMG_NAME"
fi

# Hapus folder sementara
echo "🧹 Membersihkan folder sementara..."
rm -rf "$TEMP_DMG_DIR"

# Verifikasi
if [ -f "$DMG_NAME" ]; then
  echo ""
  echo "✅ DMG berhasil dibuat!"
  echo "📁 File: $DMG_NAME"
  echo "📊 Size: $(du -h "$DMG_NAME" | cut -f1)"
  
  # Quick test
  echo "🧪 Testing DMG..."
  if hdiutil imageinfo "$DMG_NAME" >/dev/null 2>&1; then
    echo "✅ DMG structure valid"
    
    # Coba mount
    if MOUNT_OUTPUT=$(hdiutil attach "$DMG_NAME" -nobrowse -mountrandom /tmp 2>&1); then
      MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | tail -1 | cut -f3-)
      echo "✅ Bisa dimount di: $MOUNT_POINT"
      hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null
      
      echo ""
      echo "🎉 DMG siap digunakan! Coba buka dengan:"
      echo "   open \"$DMG_NAME\""
    else
      echo "⚠️  DMG valid tapi ada masalah mount"
      echo "   Output: $MOUNT_OUTPUT"
    fi
  else
    echo "❌ DMG structure tidak valid"
  fi
else
  echo "❌ Gagal membuat DMG!"
  exit 1
fi

echo ""
echo "📋 Langkah instalasi:"
echo "1. Double-click: $DMG_NAME"
echo "2. Drag '$APP_NAME.app' ke folder Applications"
echo "3. Jika ada warning 'app cannot be opened':"
echo "   - Buka Applications folder"
echo "   - Control+Click pada $APP_NAME.app"
echo "   - Pilih 'Open'"
echo "   - Klik 'Open' pada dialog"