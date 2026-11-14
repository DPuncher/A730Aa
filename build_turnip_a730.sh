#!/usr/bin/env bash
# Сборка Mesa Turnip (Adreno 730 / A7xx, kgsl) в формате AdrenoTools для Eden.
# Результат: out/turnip-a730-mesa<версия>-<хэш>[-вариант].zip с libvulkan_freedreno.so и meta.json в корне архива.
#
# Нужно: git meson ninja python3 (mako, pyyaml) flex bison glslang zip unzip curl file pkg-config
# NDK r26+ берётся из ANDROID_NDK_HOME / ANDROID_NDK_ROOT / ANDROID_NDK_LATEST_HOME,
# иначе скачивается $NDK_VER с dl.google.com.
#
# Переменные окружения (все необязательные):
#   MESA_REPO     git-адрес Mesa            (по умолчанию gitlab.freedesktop.org/mesa/mesa)
#   MESA_REF      ветка, тег или хэш коммита (2648b2059f = база рабочего Gen8 V39)
#   NDK_VER       версия NDK                (android-ndk-r29, как у V39; чужой NDK из окружения
#                 берётся, только если совпадает мажорная версия, иначе качается $NDK_VER)
#   SDK_VER       Android API level сборки  (34, как у V39)
#   PATCH_DIR     папка с *.patch / *.diff  (./patches)
#   PATCH_STRICT  1 = остановиться, если патч не применяется; 0 = пропустить (1)
#   PATCH_FUZZ    1 = если git apply не справился (контекст сдвинулся в свежем main),
#                 попробовать patch --fuzz=3 и громко предупредить; 0 = не пробовать (1)
#   SNAPSHOT      1 = сохранить в snapshot/ копии tu_knl_kgsl.cc и tu_queue.cc из скачанного Mesa
#                 и лог неудачных патчей (нужно, чтобы подогнать патчи под свежий main) (1)
#   DIAG          1 = диагностическая сборка: assert'ы включены (-Db_ndebug=false) и
#                 символы не вырезаны (-Dstrip=false), чтобы backtrace/logcat были читаемы;
#                 медленнее и крупнее, для обычной игры не нужна (0)
#   VARIANT       метка варианта в имени zip и в meta.json (пусто)
#   TU_DEFAULT_DEBUG  флаги TU_DEBUG, включённые по умолчанию, через запятую: nolrz,noubwc
#                 (вшиваются в драйвер; для проверки мерцания без adb) (пусто)
#   NO_PATCHES    1 = не применять patches/ вообще (контрольная сборка) (0)
#   LIB_NAME      имя .so в архиве и libraryName в meta.json (libvulkan_freedreno.so = SONAME)
#   MIN_API       поле minApi в meta.json   (28, как у V39)
#   NDK_ANY       1 = брать любой NDK r26+ из окружения (0)
#   AUTHOR        поле author в meta.json   (custom)
#   JOBS          число потоков ninja       (nproc)

set -euo pipefail

MESA_REPO="${MESA_REPO:-https://gitlab.freedesktop.org/mesa/mesa.git}"
MESA_REF="${MESA_REF:-2648b2059f}"
NDK_VER="${NDK_VER:-android-ndk-r29}"
SDK_VER="${SDK_VER:-34}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$ROOT/work}"
OUTDIR="${OUTDIR:-$ROOT/out}"
PATCH_DIR="${PATCH_DIR:-$ROOT/patches}"
PATCH_STRICT="${PATCH_STRICT:-1}"
PATCH_FUZZ="${PATCH_FUZZ:-1}"
DIAG="${DIAG:-0}"
SNAPSHOT="${SNAPSHOT:-1}"
AUTHOR="${AUTHOR:-custom}"
VARIANT="${VARIANT:-}"
TU_DEFAULT_DEBUG="${TU_DEFAULT_DEBUG:-}"
NO_PATCHES="${NO_PATCHES:-0}"
MIN_API="${MIN_API:-28}"
NDK_ANY="${NDK_ANY:-0}"
JOBS="${JOBS:-$(nproc)}"

LIB_NAME="${LIB_NAME:-libvulkan_freedreno.so}"
SRC="$WORKDIR/mesa"
BUILD="$WORKDIR/build-android-aarch64"
INSTALL="$WORKDIR/install"
NDK=""
NDK_BIN=""
GITHASH=""
MESA_VERSION=""
APPLIED=0

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
  local d rev major want
  want="$(sed -nE 's/^android-ndk-r([0-9]+).*/\1/p' <<<"$NDK_VER")"
  for d in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}" "${ANDROID_NDK_LATEST_HOME:-}" "$WORKDIR/$NDK_VER"; do
    [[ -n "$d" && -d "$d/toolchains/llvm/prebuilt/linux-x86_64" ]] || continue
    rev="$(sed -n 's/^Pkg.Revision *= *//p' "$d/source.properties")"
    major="${rev%%.*}"
    if ((NDK_ANY)) || [[ -z "$want" || "$major" == "$want" ]]; then
      NDK="$d"
      break
    fi
    warn "NDK $d (rev ${rev:-?}) не подходит: нужен r$want (NDK_ANY=1 разрешит любой)"
  done
  if [[ -z "$NDK" ]]; then
    log "Скачиваю $NDK_VER"
    curl -fL --retry 3 -o "$WORKDIR/$NDK_VER.zip" "https://dl.google.com/android/repository/$NDK_VER-linux.zip" \
      || die "Не удалось скачать NDK. Задай ANDROID_NDK_HOME на уже установленный NDK r$want."
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
  if [[ "$MESA_REF" =~ ^[0-9a-f]{7,40}$ ]]; then
    # Хэш коммита: shallow-fetch по короткому хэшу не работает, поэтому клон без blob'ов
    # (быстро: качаются коммиты и деревья, сами файлы — при checkout).
    if [[ ! -d "$SRC/.git" ]]; then
      git clone --filter=blob:none --no-checkout "$MESA_REPO" "$SRC"
    else
      git -C "$SRC" fetch origin
    fi
    git -C "$SRC" checkout -q -f --detach "$MESA_REF" \
      || die "Коммит $MESA_REF не найден в $MESA_REPO (он должен быть в истории main)"
    git -C "$SRC" clean -fdxq
  elif [[ -d "$SRC/.git" ]]; then
    git -C "$SRC" fetch --depth 1 origin "$MESA_REF"
    git -C "$SRC" reset --hard FETCH_HEAD
    git -C "$SRC" clean -fdxq
  else
    git clone --depth 1 --branch "$MESA_REF" "$MESA_REPO" "$SRC"
  fi
  GITHASH="$(git -C "$SRC" rev-parse --short=10 HEAD)"
  MESA_VERSION="$(tr -d '[:space:]' < "$SRC/VERSION")"
  log "Mesa $MESA_VERSION ($GITHASH)"
}

# Копия исходников, которые правят патчи, и лог неудач: по ним патчи подгоняются под текущий main.
snapshot_sources() {
  ((SNAPSHOT)) || return 0
  local d="$ROOT/snapshot" v="src/freedreno/vulkan" f
  rm -rf "$d"
  mkdir -p "$d/$v"
  for f in tu_knl_kgsl.cc tu_queue.cc; do
    cp "$SRC/$v/$f" "$d/$v/$f" || warn "не удалось сохранить $f"
  done
  printf 'mesa %s\nhash %s\ndate %s\nref  %s\n' "$MESA_VERSION" "$GITHASH" \
    "$(git -C "$SRC" log -1 --format=%cs)" "$MESA_REF" >"$d/INFO.txt"
  log "snapshot/ сохранён (Mesa $MESA_VERSION $GITHASH)"
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

# 0 = применён/уже был, 1 = не применился
apply_one_patch() {
  local p="$1" name
  name="$(basename "$p")"
  if git -C "$SRC" apply --check "$p" 2>/dev/null; then
    git -C "$SRC" apply "$p"
    APPLIED=$((APPLIED + 1))
    log "применён: $name"
  elif git -C "$SRC" apply -R --check "$p" 2>/dev/null; then
    warn "уже есть в дереве, пропуск: $name"
  elif ((PATCH_FUZZ)) \
    && (cd "$SRC" && patch -p1 -N --fuzz=3 --dry-run --silent <"$p" >/dev/null 2>&1); then
    (cd "$SRC" && patch -p1 -N --fuzz=3 --no-backup-if-mismatch --silent <"$p")
    APPLIED=$((APPLIED + 1))
    warn "применён С СДВИГОМ/FUZZ (контекст изменился в $MESA_REF): $name. Проверь, что сборка прошла."
  else
    if ((SNAPSHOT)); then
      mkdir -p "$ROOT/snapshot"
      {
        echo "=== $name vs $MESA_REF ($GITHASH)"
        git -C "$SRC" apply --check "$p" 2>&1 | head -40 || true
        (cd "$SRC" && patch -p1 -N --fuzz=3 --dry-run <"$p" 2>&1 | head -60) || true
        echo
      } >>"$ROOT/snapshot/patch-log.txt" || true
    fi
    return 1
  fi
}

apply_patches() {
  local p n=0
  if ((NO_PATCHES)); then
    log "патчи отключены (NO_PATCHES=1): контрольная сборка чистого $MESA_REF"
    return 0
  fi
  shopt -s nullglob
  for p in "$PATCH_DIR"/*.patch "$PATCH_DIR"/*.diff; do
    n=$((n + 1))
    if ! apply_one_patch "$p"; then
      if ((PATCH_STRICT)); then
        die "патч не применяется: $(basename "$p"). Обнови его под $MESA_REF или запусти с PATCH_STRICT=0"
      else
        warn "не применился, пропуск: $(basename "$p")"
      fi
    fi
  done
  shopt -u nullglob
  ((n > 0)) || log "patches/ пуст, собираю чистый $MESA_REF"
}

# Вшивает флаги TU_DEBUG по умолчанию (то же, что TU_DEBUG=... в окружении, но без adb).
# Падает с понятным сообщением, если в этом дереве код выглядит иначе.
apply_default_debug() {
  [[ -n "$TU_DEFAULT_DEBUG" ]] || return 0
  local util="$SRC/src/freedreno/vulkan/tu_util.cc" hdr="$SRC/src/freedreno/vulkan/tu_util.h" fl up
  local -a flags=()
  [[ -f "$util" && -f "$hdr" ]] || die "нет tu_util.cc/tu_util.h, TU_DEFAULT_DEBUG применить нельзя"
  IFS=',' read -ra flags <<<"$TU_DEFAULT_DEBUG"
  for fl in "${flags[@]}"; do
    fl="${fl//[[:space:]]/}"
    [[ -n "$fl" ]] || continue
    up="$(tr '[:lower:]' '[:upper:]' <<<"$fl")"
    grep -Eq "TU_DEBUG_${up}([^A-Z0-9_]|$)" "$hdr" \
      || die "в tu_util.h нет флага TU_DEBUG_${up} (TU_DEFAULT_DEBUG='$TU_DEFAULT_DEBUG')"
  done
  python3 -I - "$util" "$TU_DEFAULT_DEBUG" <<'PY' || die "не удалось вшить TU_DEFAULT_DEBUG (структура tu_util.cc изменилась)"
import re, sys
path, flags = sys.argv[1], [f.strip().upper() for f in sys.argv[2].split(',') if f.strip()]
src = open(path, encoding='utf-8').read()
m = re.search(r'^([ \t]*)tu_env\.debug\s*=[^;]*;', src, re.M)
if not m:
    sys.exit("в tu_util.cc нет присваивания tu_env.debug")
ind = m.group(1)
add = ''.join(f"\n{ind}tu_env.debug = (decltype(tu_env.debug))(tu_env.debug | TU_DEBUG_{f});" for f in flags)
open(path, 'w', encoding='utf-8').write(src[:m.end()] + add + src[m.end():])
print("TU_DEBUG по умолчанию вшит:", ",".join(flags))
PY
  log "TU_DEBUG по умолчанию: $TU_DEFAULT_DEBUG"
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
  local ndebug=true strip=true
  if ((DIAG)); then
    ndebug=false
    strip=false
    warn "DIAG=1: assert'ы включены, символы не вырезаны (медленнее и крупнее)"
  fi
  log "meson setup"
  rm -rf "$BUILD" "$INSTALL"
  (
    cd "$SRC"
    meson setup "$BUILD" \
      --cross-file "$WORKDIR/android-aarch64.txt" \
      --native-file "$WORKDIR/native.txt" \
      --prefix "$INSTALL" \
      -Dbuildtype=release \
      -Db_ndebug="$ndebug" \
      -Dstrip="$strip" \
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
  local soname
  soname="$("$NDK_BIN/llvm-readelf" -d "$lib" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')"
  if [[ "$soname" != "$LIB_NAME" ]]; then
    warn "SONAME (${soname:-?}) не совпадает с именем файла в архиве ($LIB_NAME)"
  fi
  log "ELF aarch64 ок, SONAME ${soname:-?}, размер $(du -h "$lib" | cut -f1)"
}

package() {
  # Метка в имени, чтобы в Eden/AdrenoTools можно было отличить сборки: pN = число применённых патчей.
  local tag=""
  ((APPLIED > 0)) && tag="-p${APPLIED}"
  ((DIAG)) && tag="${tag}-diag"
  [[ -n "$VARIANT" ]] && tag="${tag}-${VARIANT}"
  local pkg="$OUTDIR/pkg" zip_name="turnip-a730-mesa${MESA_VERSION}-${GITHASH}${tag}.zip"
  rm -rf "$pkg"
  mkdir -p "$pkg"
  cp "$INSTALL/lib/libvulkan_freedreno.so" "$pkg/$LIB_NAME"

  python3 -I - "$pkg/meta.json" "$MESA_VERSION" "$GITHASH$tag" "$AUTHOR" "$MIN_API" "$LIB_NAME" <<'PY'
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
  snapshot_sources
  report_features
  apply_patches
  apply_default_debug
  write_cross_files
  build
  verify_lib
  package
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
