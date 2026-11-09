#!/bin/sh
# ios-tweak-build.sh — 用 Apelin 装的工具链 + iOS SDK，把一组 Objective-C 源码
# 编译成 rootless 越狱插件的 dylib，并打成一个 .deb。不需要 Theos。
#
# 用法（在项目根目录）：
#   NAME=MyTweak PKG=bc.8848.mytweak FILTER=com.apple.springboard \
#     SRC=Sources ./tools/ios-tweak-build.sh
#
# 环境变量：
#   NAME      dylib 与 filter 的文件名        （必填，如 MyTweak）
#   PKG       Debian 包名                     （必填，如 bc.8848.mytweak）
#   FILTER    注入的 bundle id，逗号分隔       （必填，如 com.apple.springboard）
#   VER       版本，默认 1.0.0
#   AUTHOR    作者，默认 8848
#   SRC       源码目录，默认 Sources（取其下 *.m）
#   FRAMEWORKS 额外框架，空格分隔，默认 "Foundation UIKit"
#   OUT       产物目录，默认 build
#   BOOTSTRAP rootless（默认）或 roothide
#
# 产物：$OUT/<PKG>_<VER>_<arch>.deb
# 安装：本脚本只打包。装包要 sudo/包管理器，见 ~/.dsh/docs/ios-build.md。
set -eu

: "${NAME:?需要 dylib 名字，例如 NAME=MyTweak}"
: "${PKG:?需要包名，例如 PKG=bc.8848.mytweak}"
: "${FILTER:?需要注入的 bundle id，例如 FILTER=com.apple.springboard}"
VER="${VER:-1.0.0}"
AUTHOR="${AUTHOR:-8848}"
SRC="${SRC:-Sources}"
OUT="${OUT:-build}"
FRAMEWORKS="${FRAMEWORKS:-Foundation UIKit}"
BOOTSTRAP="${BOOTSTRAP:-rootless}"

TOOLCHAIN="${TOOLCHAIN:-/var/jb/usr/lib/apelin/toolchains/67525fd44741f8a0f7d7b2e7/usr/bin}"
SDK="${SDK:-/var/mobile/Documents/wiki.qaq.apelin/SDKs/iphoneos17.2-96db0f3e}"
DEV="${DEV:-/var/jb/usr/share/apelin/development/wiki.qaq.apelin.dev.tweak}"
CC="$TOOLCHAIN/clang"
LIPO="$TOOLCHAIN/lipo"
STRIP="$TOOLCHAIN/strip"

case "$BOOTSTRAP" in
rootless) ARCHES="arm64 arm64e"; ARCH_NAME="iphoneos-arm64"; STAGE_BASE_REL="var/jb" ;;
roothide) ARCHES="arm64e"; ARCH_NAME="iphoneos-arm64e"; STAGE_BASE_REL="" ;;
*) echo "BOOTSTRAP 只能是 rootless 或 roothide" >&2; exit 2 ;;
esac

[ -x "$CC" ] || { echo "找不到 clang：$CC" >&2; exit 2; }
[ -d "$SDK" ] || { echo "找不到 SDK：$SDK" >&2; exit 2; }
set -- "$SRC"/*.m
[ -f "$1" ] || { echo "$SRC 下没有 .m 文件" >&2; exit 2; }

WORK=""
for base in "${TMPDIR:-}" "$HOME/.cache" /tmp; do
  [ -n "$base" ] || continue
  mkdir -p "$base" 2>/dev/null || continue
  [ -w "$base" ] || continue
  if WORK=$(mktemp -d "$base/iosbuild.XXXXXX" 2>/dev/null); then break; fi
done
[ -n "$WORK" ] || { echo "找不到可写的临时目录" >&2; exit 2; }
STAGE="$WORK/stage"
trap 'rm -rf -- "${WORK:?}"' EXIT
mkdir -p "$STAGE/DEBIAN" "$OUT"

OBJS=""
for arch in $ARCHES; do
  mkdir -p "$WORK/obj/$arch"
  for src in "$@"; do
    obj="$WORK/obj/$arch/$(basename "${src%.m}").o"
    "$CC" -isysroot "$SDK" -arch "$arch" -mios-version-min=16.0 \
      -O2 -fobjc-arc -fvisibility=hidden -Wall \
      -Werror=unguarded-availability-new \
      -I"$DEV/support/include" \
      -c "$src" -o "$obj"
    OBJS="$OBJS $obj"
  done
  link_args=""
  for fw in $FRAMEWORKS; do link_args="$link_args -framework $fw"; done
  # shellcheck disable=SC2086
  "$CC" -isysroot "$SDK" -arch "$arch" -mios-version-min=16.0 -dynamiclib \
    -L"$DEV/support/lib/$BOOTSTRAP" -lsubstrate \
    $link_args \
    -install_name "@rpath/$NAME.dylib" \
    -o "$WORK/$NAME.$arch.dylib" $OBJS
  OBJS=""
done

if [ "$BOOTSTRAP" = rootless ]; then
  "$LIPO" -create "$WORK/$NAME.arm64.dylib" "$WORK/$NAME.arm64e.dylib" \
    -output "$WORK/$NAME.dylib"
else
  cp "$WORK/$NAME.arm64e.dylib" "$WORK/$NAME.dylib"
fi
"$STRIP" -x "$WORK/$NAME.dylib"
ldid -S "$WORK/$NAME.dylib"

mkdir -p "$STAGE/DEBIAN"
# rootless 的 deb 以 var/jb/ 开头（引导区相对 /），roothide 则直接在根上
STAGE_ROOT="$STAGE"
[ -n "$STAGE_BASE_REL" ] && STAGE_ROOT="$STAGE/$STAGE_BASE_REL"
mkdir -p "$STAGE_ROOT/Library/MobileSubstrate/DynamicLibraries"
cp "$WORK/$NAME.dylib" "$STAGE_ROOT/Library/MobileSubstrate/DynamicLibraries/"

# 注入过滤：Filter.Bundles 里每个 bundle id 一行
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0">\n<dict>\n\t<key>Filter</key>\n\t<dict>\n\t\t<key>Bundles</key>\n\t\t<array>\n'
  printf '%s' "$FILTER" | tr ',' '\n' | while IFS= read -r b; do
    [ -n "$b" ] && printf '\t\t\t<string>%s</string>\n' "$b"
  done
  printf '\t\t</array>\n\t</dict>\n</dict>\n</plist>\n'
} >"$STAGE_ROOT/Library/MobileSubstrate/DynamicLibraries/$NAME.plist"

cat >"$STAGE/DEBIAN/control" <<EOF
Package: $PKG
Name: $NAME
Version: $VER
Architecture: $ARCH_NAME
Description: $NAME
Author: $AUTHOR
Maintainer: $AUTHOR
Section: Tweaks
Depends: mobilesubstrate
EOF

DEB="$OUT/${PKG}_${VER}_${ARCH_NAME}.deb"
# dpkg-deb 也用 TMPDIR，而 launchd/终端给的 TMPDIR 往往在不可写的引导区里
TMPDIR="$WORK" dpkg-deb -b --root-owner-group "$STAGE" "$DEB" >/dev/null
echo "$DEB"
