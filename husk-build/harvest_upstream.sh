#!/bin/bash
# 从上游 release 的 Husk.ipa 里取出"原生核"产物，摆成 Husk 源码树期望的布局。
#
# 用途：只重编应用层（Swift/ObjC/C 的 Husk.app）时，QEMU/ANGLE/MoltenVK/PS4 这些
# 需要几小时交叉编译的东西可以直接复用上游 tag 对应的成品，保证 ABI 一致。
#
#   bash harvest_upstream.sh <husk 源码目录> [--only-missing]
set -euo pipefail

ROOT="${1:?用法: harvest_upstream.sh <husk 源码目录> [--only-missing]}"
ONLY_MISSING="${2:-}"
HUSK_REF="${HUSK_REF:-3.4}"
WORK="${WORK:-/tmp/husk-upstream}"
IPA="$WORK/Husk.ipa"

mkdir -p "$WORK"
if [ ! -s "$IPA" ]; then
    echo "==> 下载上游 Husk $HUSK_REF"
    curl -fL --retry 3 --retry-delay 5 -o "$IPA.part" \
        "https://github.com/Leviidev/Husk/releases/download/${HUSK_REF}/Husk.ipa"
    mv "$IPA.part" "$IPA"
fi
echo "==> 上游 IPA: $(du -h "$IPA" | cut -f1)"

rm -rf "$WORK/x"
mkdir -p "$WORK/x"
unzip -q "$IPA" -d "$WORK/x"
APP="$WORK/x/Payload/Husk.app"
[ -d "$APP" ] || { echo "!! 上游 IPA 里没有 Husk.app" >&2; exit 1; }

LIB="$ROOT/build/ios-arm64/lib"
SYSROOT_LIB="$ROOT/build/ios-arm64/sysroot/lib"
BIOS="$ROOT/third_party/build/qemu-10.0.12-utm/pc-bios"
mkdir -p "$LIB" "$SYSROOT_LIB" "$BIOS" "$ROOT/guests/phase0"

have() { [ -n "$ONLY_MISSING" ] && [ -e "$1" ]; }

# 1) QEMU / PS4 / ANGLE 动态库
if ! have "$LIB/libqemu-aarch64-softmmu.dylib"; then
    cp -f "$APP/Frameworks/libqemu-aarch64-softmmu.dylib" "$LIB/"
    echo "[put] libqemu-aarch64-softmmu.dylib"
fi
if ! have "$LIB/libhuskps4.dylib"; then
    cp -f "$APP/Frameworks/libhuskps4.dylib" "$LIB/"
    echo "[put] libhuskps4.dylib"
fi
if ! have "$SYSROOT_LIB/libANGLE-shared.dylib"; then
    cp -f "$APP/Frameworks/libANGLE-shared.dylib" "$SYSROOT_LIB/"
    echo "[put] libANGLE-shared.dylib"
fi

# 2) MoltenVK：还原成 xcframework 结构（project.yml 引用的是 xcframework）
MVK="$LIB/MoltenVK.xcframework"
if ! have "$MVK/ios-arm64/MoltenVK.framework/MoltenVK"; then
    rm -rf "$MVK"
    mkdir -p "$MVK/ios-arm64"
    ditto "$APP/Frameworks/MoltenVK.framework" "$MVK/ios-arm64/MoltenVK.framework"
    cat > "$MVK/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>
            <string>ios-arm64</string>
            <key>LibraryPath</key>
            <string>MoltenVK.framework</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>ios</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST
    echo "[put] MoltenVK.xcframework"
fi

# 3) Java 运行时 / Android 系统资源（Java 应用和 Flutter 需要；源码构建要 APEX 镜像，这里直接取成品）
if ! have "$ROOT/build/java-runtime/husk-framework.dex"; then
    rm -rf "$ROOT/build/java-runtime"
    cp -R "$APP/java-runtime" "$ROOT/build/java-runtime"
    echo "[put] java-runtime ($(du -sh "$ROOT/build/java-runtime" | cut -f1))"
fi
if ! have "$ROOT/build/android-system/fonts/fonts.xml"; then
    rm -rf "$ROOT/build/android-system"
    cp -R "$APP/android-system" "$ROOT/build/android-system"
    echo "[put] android-system"
fi

# 4) guest 内核 / initramfs / UEFI 固件 / 空盘种子
if ! have "$ROOT/guests/phase0/vmlinuz-virt"; then
    cp -f "$APP/vmlinuz-virt" "$APP/initramfs-virt" "$ROOT/guests/phase0/"
    echo "[put] vmlinuz-virt + initramfs-virt"
fi
if ! have "$ROOT/guests/phase0/edk2-aarch64-code.fd"; then
    cp -f "$APP/edk2-aarch64-code.fd" "$ROOT/guests/phase0/"
    echo "[put] edk2-aarch64-code.fd"
fi
# project.yml 的 preBuild 阶段从 QEMU 的 pc-bios 里取 efi/pxe ROM，并 bunzip2 出 edk2
cp -f "$APP"/pc-bios/*.rom "$BIOS/" 2>/dev/null || true
if [ ! -f "$BIOS/edk2-aarch64-code.fd.bz2" ]; then
    bzip2 -c "$APP/edk2-aarch64-code.fd" > "$BIOS/edk2-aarch64-code.fd.bz2"
    echo "[put] pc-bios: $(ls "$BIOS" | wc -l | tr -d ' ') 个 ROM + edk2.bz2"
fi

echo "==> 备料完成"
du -sh "$LIB" "$ROOT/build/java-runtime" "$ROOT/build/android-system" "$ROOT/guests/phase0" 2>/dev/null || true
