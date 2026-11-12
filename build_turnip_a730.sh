#!/usr/bin/env bash
# Сборка Mesa Turnip (Adreno 730 / A7xx, kgsl) в формате AdrenoTools для Eden.
# Результат: out/turnip-a730-mesa<версия>-<хэш>.zip с vulkan.adreno.so и meta.json в корне архива.
#
# Нужно: git meson ninja python3 (mako, pyyaml) flex bison glslang zip unzip curl file pkg-config
# NDK r26+ берётся из ANDROID_NDK_HOME / ANDROID_NDK_ROOT / ANDROID_NDK_LATEST_HOME,
# иначе скачивается $NDK_VER с dl.google.com.
#
# Переменные окружения (все необязательные):
#   MESA_REPO     git-адрес Mesa            (по умолчанию gitlab.freedesktop.org/mesa/mesa)
#   MESA_REF      ветка или тег             (main)
#   NDK_VER       версия NDK для загрузки   (android-ndk-r27c)
#   SDK_VER       Android API level         (31)
#   PATCH_DIR     папка с *.patch / *.diff  (./patches)
#   PATCH_STRICT  1 = остановиться, если патч не применяется; 0 = пропустить (1)
#   AUTHOR        поле author в meta.json   (custom)
#   JOBS          число потоков ninja       (nproc)

set -euo pipefail

MESA_REPO="${MESA_REPO:-https://gitlab.freedesktop.org/mesa/mesa.git}"
MESA_REF="${MESA_REF:-main}"
NDK_VER="${NDK_VER:-android-ndk-r27c}"
SDK_VER="${SDK_VER:-31}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$ROOT/work}"
OUTDIR="${OUTDIR:-$ROOT/out}"
PATCH_DIR="${PATCH_DIR:-$ROOT/patches}"
PATCH_STRICT="${PATCH_STRICT:-1}"
AUTHOR="${AUTHOR:-custom}"
JOBS="${JOBS:-$(nproc)}"

LIB_NAME="vulkan.adreno.so"
SRC="$WORKDIR/mesa"
BUILD="$WORKDIR/build-android-aarch64"
INSTALL="$WORKDIR/install"
NDK=""
NDK_BIN=""
GITHASH=""
MESA_VERSION=""

log()  { printf '\033[0;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[0;33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[0;31mXX  %s\033[0m\n' "$*" >&2; exit 1; }

check_deps() {
  log "Проверка зависимостей"
  local missing=0 t
  for t in git meson ninja python3 flex bison zip unzip curl file pkg-config; do
    command -v "$t" >/dev/null || { warn "не найден: $t"; missing=1; }
  done
  command -v glslangValidator >/dev/null || command -v glslang >/dev/null \
    || { warn "не найден: glslang (glslangValidator)"; missing=1; }
  python3 -c 'import mako' 2>/dev/null || { warn "нет python-модуля mako"; missing=1; }
  python3 -c 'import yaml' 2>/dev/null || { warn "нет python-модуля pyyaml"; missing=1; }
  ((missing == 0)) || die "Установи недостающее. Ubuntu: sudo apt install git ninja-build flex bison glslang-tools zip unzip curl file pkg-config python3-pip && pip install meson mako pyyaml"
}

resolve_ndk() {
  local d rev major
  for d in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_LATEST_HOME:-}" "$WORKDIR/$NDK_VER"; do
    if [[ -n "$d" && -d "$d/toolchains/llvm/prebuilt/linux-x86_64" ]]; then
      NDK="$d"
      break
    fi
  done
  if [[ -z "$NDK" ]]; then
    log "NDK не найден, скачиваю $NDK_VER"
    curl -fL --retry 3 -o "$WORKDIR/$NDK_VER.zip" "https://dl.google.com/android/repository/$NDK_VER-linux.zip" \
      || die "Не удалось скачать NDK. Задай ANDROID_NDK_HOME на уже установленный NDK r26+."
    unzip -q -o "$WORKDIR/$NDK_VER.zip" -d "$WORKDIR"
    NDK="$WORKDIR/$NDK_VER"
  fi
  rev="$(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties")"
  major="${rev%%.*}"
  if ! [[ "$major" =~ ^[0-9]+$ ]] || ((major < 26)); then
    die "Нужен NDK r26+, найден: ${rev:-неизвестно} ($NDK)"
  fi
  NDK_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
  log "NDK: $NDK (rev $rev), target aarch64-linux-android$SDK_VER"
}

fetch_mesa() {
  log "Исходники Mesa: $MESA_REPO @ $MESA_REF"
  if [[ -d "$SRC/.git" ]]; then
    git -C "$SRC" fetch --depth 1 origin "$MESA_REF"
    git -C "$SRC" reset --hard FETCH_HEAD
    git -C "$SRC" clean -fdxq
  else
    git clone --depth 1 --branch "$MESA_REF" "$MESA_REPO" "$SRC"
  fi
  GITHASH="$(git -C "$SRC" rev-parse --short HEAD)"
  MESA_VERSION="$(tr -d '[:space:]' < "$SRC/VERSION")"
  log "Mesa $MESA_VERSION ($GITHASH)"
}

# Показывает, есть ли нужные расширения в этом дереве, чтобы не накладывать лишние патчи.
report_features() {
  local f="$SRC/src/freedreno/vulkan/tu_device.cc" ext
  log "Расширения Turnip в этом дереве"
  [[ -f "$f" ]] || { warn "нет $f, проверка пропущена"; return 0; }
  for ext in EXT_descriptor_buffer EXT_extended_dynamic_state3 KHR_dynamic_rendering; do
    if grep -Eq "\.${ext}[[:space:]]*=" "$f"; then
      echo "   есть   VK_${ext}"
    else
      echo "   нет    VK_${ext}  (нужен патч, положи его в $PATCH_DIR)"
    fi
  done
}

apply_patches() {
  local p n=0
  shopt -s nullglob
  for p in "$PATCH_DIR"/*.patch "$PATCH_DIR"/*.diff; do
    n=$((n + 1))
    if git -C "$SRC" apply --check "$p" 2>/dev/null; then
      git -C "$SRC" apply "$p"
      log "применён: $(basename "$p")"
    elif git -C "$SRC" apply -R --check "$p" 2>/dev/null; then
      warn "уже есть в дереве, пропуск: $(basename "$p")"
    elif ((PATCH_STRICT)); then
      die "патч не применяется: $(basename "$p"). Обнови его под $MESA_REF или запусти с PATCH_STRICT=0"
    else
      warn "не применился, пропуск: $(basename "$p")"
    fi
  done
  shopt -u nullglob
  ((n > 0)) || log "patches/ пуст, собираю чистый $MESA_REF"
}

write_cross_files() {
  local cache="" ncc nxx
  command -v ccache >/dev/null && cache="'ccache', "
  ncc="$(command -v clang || command -v gcc)"
  nxx="$(command -v clang++ || command -v g++)"
  mkdir -p "$WORKDIR/empty-pkgconfig"

  cat > "$WORKDIR/android-aarch64.txt" <<EOF
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = [${cache}'$NDK_BIN/aarch64-linux-android${SDK_VER}-clang']
cpp = [${cache}'$NDK_BIN/aarch64-linux-android${SDK_VER}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$NDK_BIN/ld.lld'
cpp_ld = '$NDK_BIN/ld.lld'
strip = '$NDK_BIN/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$WORKDIR/empty-pkgconfig', '$(command -v pkg-config)']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

  cat > "$WORKDIR/native.txt" <<EOF
[binaries]
c = ['$ncc']
cpp = ['$nxx']
EOF
}

build() {
  log "meson setup"
  rm -rf "$BUILD" "$INSTALL"
  (
    cd "$SRC"
    meson setup "$BUILD" \
      --cross-file "$WORKDIR/android-aarch64.txt" \
      --native-file "$WORKDIR/native.txt" \
      --prefix "$INSTALL" \
      -Dbuildtype=release \
      -Db_ndebug=true \
      -Dstrip=true \
      -Dplatforms=android \
      -Dplatform-sdk-version="$SDK_VER" \
      -Dandroid-stub=true \
      -Dandroid-libbacktrace=disabled \
      -Dgallium-drivers= \
      -Dvulkan-drivers=freedreno \
      -Dfreedreno-kmds=kgsl \
      -Dvulkan-beta=true \
      -Dvideo-codecs= \
      -Degl=disabled \
      -Dllvm=disabled
  )
  log "ninja ($JOBS потоков)"
  ninja -C "$BUILD" -j "$JOBS" install
}

verify_lib() {
  local lib="$INSTALL/lib/libvulkan_freedreno.so"
  [[ -f "$lib" ]] || die "Сборка не создала $lib"
  file "$lib" | grep -q 'ARM aarch64' || die "Не aarch64 ELF: $(file "$lib")"
  if ! "$NDK_BIN/llvm-nm" -D --defined-only "$lib" | grep -Eq ' (HMI|vk_icdGetInstanceProcAddr)$'; then
    warn "в библиотеке не видно HMI / vk_icdGetInstanceProcAddr, проверь сборку"
  fi
  log "ELF aarch64 ок, размер $(du -h "$lib" | cut -f1)"
}

package() {
  local pkg="$OUTDIR/pkg" zip_name="turnip-a730-mesa${MESA_VERSION}-${GITHASH}.zip"
  rm -rf "$pkg"
  mkdir -p "$pkg"
  cp "$INSTALL/lib/libvulkan_freedreno.so" "$pkg/$LIB_NAME"

  python3 -I - "$pkg/meta.json" "$MESA_VERSION" "$GITHASH" "$AUTHOR" "$SDK_VER" "$LIB_NAME" <<'PY'
import json, sys
out, ver, h, author, minapi, lib = sys.argv[1:7]
meta = {
    "schemaVersion": 1,
    "name": f"Mesa Turnip A730 {ver}-{h}",
    "description": "Mesa Turnip (Freedreno) Vulkan driver for Adreno 730 (Snapdragon 8+ Gen 1, SM8475), built for AdrenoTools / Eden",
    "author": author,
    "packageVersion": "1",
    "vendor": "Mesa",
    "driverVersion": f"Mesa {ver}-{h}",
    "minApi": int(minapi),
    "libraryName": lib,
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2)
    f.write("\n")
PY

  python3 -I -m json.tool "$pkg/meta.json" >/dev/null || die "meta.json невалиден"
  rm -f "$OUTDIR/$zip_name"
  (cd "$pkg" && zip -9 -X "$OUTDIR/$zip_name" "$LIB_NAME" meta.json)
  unzip -l "$OUTDIR/$zip_name"
  log "Готово: $OUTDIR/$zip_name"
}

main() {
  mkdir -p "$WORKDIR" "$OUTDIR"
  check_deps
  resolve_ndk
  fetch_mesa
  report_features
  apply_patches
  write_cross_files
  build
  verify_lib
  package
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
