#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT_DIR/src-tauri/binaries"
IP_TOOLS_MANIFEST="$ROOT_DIR/src-tauri/ip-tools/Cargo.toml"

target_triple=""
platform=""

usage() {
  cat >&2 <<'EOF'
usage: prepare-tauri-sidecars.sh --target <rust-target-triple> [--platform <macos|linux|windows>]

Prepares Tauri externalBin sidecars for the requested target. CI can provide
prebuilt platform tools through:

  UFDE_SIDECAR_ARCHIVE_URL

The archive may contain files either at its root or in fde-cli/ and
ip-generator/ subdirectories. Files must use Tauri's target suffix, for example:

  fde-cli/bitgen-x86_64-unknown-linux-gnu
  ip-generator/ip_generator-x86_64-pc-windows-msvc.exe
EOF
}

cpu_count() {
  getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      target_triple="${2:-}"
      shift 2
      ;;
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$target_triple" ]]; then
  case "$(uname -s)" in
    Darwin) target_triple="$(rustc -vV | awk '/host:/ {print $2}')" ;;
    Linux) target_triple="$(rustc -vV | awk '/host:/ {print $2}')" ;;
    MINGW*|MSYS*|CYGWIN*) target_triple="$(rustc -vV | awk '/host:/ {print $2}')" ;;
    *)
      echo "Unable to infer target triple; pass --target." >&2
      exit 2
      ;;
  esac
fi

if [[ -z "$platform" ]]; then
  case "$target_triple" in
    *apple-darwin*) platform="macos" ;;
    *unknown-linux-gnu*) platform="linux" ;;
    *pc-windows-msvc*) platform="windows" ;;
    *)
      echo "Unable to infer platform from target '$target_triple'; pass --platform." >&2
      exit 2
      ;;
  esac
fi

case "$platform" in
  macos|linux|windows) ;;
  *)
    echo "Unsupported platform: $platform" >&2
    exit 2
    ;;
esac

exe_suffix=""
if [[ "$platform" == "windows" ]]; then
  exe_suffix=".exe"
fi

mkdir -p "$BIN_DIR/fde-cli" "$BIN_DIR/ip-generator"

download_sidecar_archive() {
  local url="${UFDE_SIDECAR_ARCHIVE_URL:-}"
  if [[ -z "$url" ]]; then
    return 0
  fi

  local tmpdir archive
  tmpdir="$(mktemp -d)"
  archive="$tmpdir/sidecars"

  echo "Downloading prebuilt sidecars from UFDE_SIDECAR_ARCHIVE_URL."
  curl -fL "$url" -o "$archive"

  mkdir -p "$tmpdir/extract"
  case "$url" in
    *.tar.gz|*.tgz) tar -xzf "$archive" -C "$tmpdir/extract" ;;
    *.tar.xz) tar -xJf "$archive" -C "$tmpdir/extract" ;;
    *.tar) tar -xf "$archive" -C "$tmpdir/extract" ;;
    *.zip) unzip -q "$archive" -d "$tmpdir/extract" ;;
    *)
      if tar -tf "$archive" >/dev/null 2>&1; then
        tar -xf "$archive" -C "$tmpdir/extract"
      else
        unzip -q "$archive" -d "$tmpdir/extract"
      fi
      ;;
  esac

  shopt -s nullglob
  for dir in fde-cli ip-generator; do
    for file in "$tmpdir/extract/$dir"/*; do
      [[ -f "$file" ]] || continue
      cp -f "$file" "$BIN_DIR/$dir/$(basename "$file")"
      chmod +x "$BIN_DIR/$dir/$(basename "$file")" 2>/dev/null || true
    done
  done

  for name in bitgen import map nlfiner pack place route sta viewer yosys yosys-abc ip_generator img2mif; do
    for file in "$tmpdir/extract/$name"*; do
      [[ -f "$file" ]] || continue
      if [[ "$name" == "ip_generator" || "$name" == "img2mif" ]]; then
        cp -f "$file" "$BIN_DIR/ip-generator/$(basename "$file")"
        chmod +x "$BIN_DIR/ip-generator/$(basename "$file")" 2>/dev/null || true
      elif [[ "$name" == "yosys" || "$name" == "yosys-abc" ]]; then
        cp -f "$file" "$BIN_DIR/$(basename "$file")"
        chmod +x "$BIN_DIR/$(basename "$file")" 2>/dev/null || true
      else
        cp -f "$file" "$BIN_DIR/fde-cli/$(basename "$file")"
        chmod +x "$BIN_DIR/fde-cli/$(basename "$file")" 2>/dev/null || true
      fi
    done
  done
  shopt -u nullglob
}

build_ip_tools() {
  if [[ "$platform" == "linux" ]]; then
    cargo build \
      --manifest-path "$IP_TOOLS_MANIFEST" \
      --release \
      --target "$target_triple" \
      --bin viewer
  else
    cargo build \
      --manifest-path "$IP_TOOLS_MANIFEST" \
      --release \
      --target "$target_triple"
  fi

  local target_dir="$ROOT_DIR/src-tauri/ip-tools/target/$target_triple/release"

  if [[ "$platform" != "linux" ]]; then
    cp "$target_dir/ip_generator$exe_suffix" "$BIN_DIR/ip-generator/ip_generator-$target_triple$exe_suffix"
    cp "$target_dir/img2mif$exe_suffix" "$BIN_DIR/ip-generator/img2mif-$target_triple$exe_suffix"
    chmod +x "$BIN_DIR/ip-generator/ip_generator-$target_triple$exe_suffix" \
      "$BIN_DIR/ip-generator/img2mif-$target_triple$exe_suffix" 2>/dev/null || true
  fi

  cp "$target_dir/viewer$exe_suffix" "$BIN_DIR/fde-cli/viewer-$target_triple$exe_suffix"
  chmod +x "$BIN_DIR/fde-cli/viewer-$target_triple$exe_suffix" 2>/dev/null || true
}

build_ip_generator() {
  if [[ "$platform" != "linux" ]]; then
    return 0
  fi

  local ip_gen_dir="${IP_GENERATOR_DIR:-}"
  if [[ -z "$ip_gen_dir" ]]; then
    if [[ -d "$ROOT_DIR/IP-Generator" ]]; then
      ip_gen_dir="$ROOT_DIR/IP-Generator"
    elif [[ -d "$ROOT_DIR/../IP-Generator" ]]; then
      ip_gen_dir="$ROOT_DIR/../IP-Generator"
    else
      return 0
    fi
  fi

  if [[ ! -d "$ip_gen_dir" ]]; then
    return 0
  fi

  local has_all=1
  for name in ip_generator img2mif; do
    if [[ ! -f "$BIN_DIR/ip-generator/$name-$target_triple$exe_suffix" ]]; then
      has_all=0
      break
    fi
  done
  if [[ "$has_all" -eq 1 ]]; then
    echo "IP-Generator sidecars already exist; skipping build."
    return 0
  fi

  echo "Building IP-Generator sidecars from $ip_gen_dir."
  cd "$ip_gen_dir"
  pyinstaller ip_generator.spec
  pyinstaller img2mif.spec
  cd "$ROOT_DIR"

  local dist_dir="$ip_gen_dir/dist"
  cp "$dist_dir/ip_generator$exe_suffix" "$BIN_DIR/ip-generator/ip_generator-$target_triple$exe_suffix"
  cp "$dist_dir/img2mif$exe_suffix" "$BIN_DIR/ip-generator/img2mif-$target_triple$exe_suffix"
  chmod +x "$BIN_DIR/ip-generator/ip_generator-$target_triple$exe_suffix" \
    "$BIN_DIR/ip-generator/img2mif-$target_triple$exe_suffix" 2>/dev/null || true
}

copy_with_suffix() {
  local source="$1"
  local destination="$2"
  [[ -f "$source" ]] || return 1
  cp -f "$source" "$destination"
  chmod +x "$destination" 2>/dev/null || true
}

prepare_fde_from_source() {
  if [[ "$platform" == "windows" ]]; then
    return 0
  fi

  local required_fde=(bitgen import map nlfiner pack place route sta)
  local has_all=1
  for name in "${required_fde[@]}"; do
    if [[ ! -f "$BIN_DIR/fde-cli/$name-$target_triple$exe_suffix" ]]; then
      has_all=0
      break
    fi
  done
  if [[ "$has_all" -eq 1 ]]; then
    echo "FDE CLI sidecars already exist; skipping FDE source build."
    return 0
  fi

  local fde_source_dir="${FDE_SOURCE_DIR:-}"
  if [[ -z "$fde_source_dir" ]]; then
    if [[ -d "$ROOT_DIR/FDE-Source" ]]; then
      fde_source_dir="$ROOT_DIR/FDE-Source"
    elif [[ -d "$ROOT_DIR/../FDE-Source" ]]; then
      fde_source_dir="$ROOT_DIR/../FDE-Source"
    else
      return 0
    fi
  fi

  if [[ ! -d "$fde_source_dir" ]]; then
    return 0
  fi

  local build_viewer="OFF"
  if [[ "$platform" == "linux" && "${UFDE_BUILD_FDE_VIEWER:-0}" == "1" ]]; then
    build_viewer="ON"
  fi

  local build_dir="${FDE_BUILD_DIR:-$fde_source_dir/build-codex-$target_triple}"
  echo "Building FDE CLI sidecars from $fde_source_dir."
  local cmake_args=(-DVIEWER="$build_viewer" -DCMAKE_BUILD_TYPE=Release)
  if [[ "$platform" == "linux" && "$build_viewer" == "ON" ]]; then
    cmake_args+=(
      -DQt5_DIR="$HOME/Qt5.14.2/5.14.2/gcc_64/lib/cmake/Qt5"
      -DCMAKE_INSTALL_RPATH='$ORIGIN/../libs'
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=TRUE
    )
  fi
  if [[ "$platform" == "macos" ]]; then
    local icu4c_prefix="${ICU4C_PREFIX:-}"
    if [[ -z "$icu4c_prefix" ]] && command -v brew >/dev/null 2>&1; then
      icu4c_prefix="$(brew --prefix icu4c 2>/dev/null || true)"
    fi
    if [[ -n "$icu4c_prefix" ]]; then
      cmake_args+=(
        -DCMAKE_EXE_LINKER_FLAGS="-L$icu4c_prefix/lib"
        -DCMAKE_SHARED_LINKER_FLAGS="-L$icu4c_prefix/lib"
      )
    fi
  fi

  if [[ "$platform" == "linux" ]]; then
    local build_dir="$fde_source_dir/build"
    echo "Building FDE from source (Linux) at $build_dir"
    mkdir -p "$build_dir"
    cd "$build_dir"
    cmake -GNinja \
      -DCMAKE_BUILD_TYPE=Release \
      -DVIEWER=ON \
      -DQt5_DIR="$HOME/Qt5.14.2/5.14.2/gcc_64/lib/cmake/Qt5" \
      -DCMAKE_INSTALL_RPATH='$ORIGIN/libs' \
      -DCMAKE_BUILD_WITH_INSTALL_RPATH=TRUE \
      ..
    ninja
    cmake --install .

    if command -v patchelf >/dev/null 2>&1; then
      if [[ -f ./viewer/plugins/platforms/libqxcb.so ]]; then
        patchelf --set-rpath '$ORIGIN/../../libs' ./viewer/plugins/platforms/libqxcb.so
      fi
      if [[ -f ./viewer/FDE ]]; then
        mv ./viewer/FDE ./viewer/viewer
      fi
      if [[ -f ./viewer/viewer ]]; then
        patchelf --set-rpath '$ORIGIN/libs' ./viewer/viewer
      fi
    fi

    cd "$ROOT_DIR"

    copy_with_suffix "$build_dir/bitgen/bitgen$exe_suffix" "$BIN_DIR/fde-cli/bitgen-$target_triple$exe_suffix" || true
    copy_with_suffix "$build_dir/vl2xml/import$exe_suffix" "$BIN_DIR/fde-cli/import-$target_triple$exe_suffix" || true
    copy_with_suffix "$build_dir/mapping/map$exe_suffix" "$BIN_DIR/fde-cli/map-$target_triple$exe_suffix" || true
    copy_with_suffix "$build_dir/NLFiner/nlfiner$exe_suffix" "$BIN_DIR/fde-cli/nlfiner-$target_triple$exe_suffix" || true
    copy_with_suffix "$build_dir/packing/pack$exe_suffix" "$BIN_DIR/fde-cli/pack-$target_triple$exe_suffix" || true
    copy_with_suffix "$build_dir/placer/place$exe_suffix" "$BIN_DIR/fde-cli/place-$target_triple$exe_suffix" || true
    copy_with_suffix "$build_dir/router/route$exe_suffix" "$BIN_DIR/fde-cli/route-$target_triple$exe_suffix" || true
    copy_with_suffix "$build_dir/sta/sta$exe_suffix" "$BIN_DIR/fde-cli/sta-$target_triple$exe_suffix" || true

    mkdir -p "$ROOT_DIR/src-tauri/linux-bin"
    if [[ -f "$build_dir/viewer/viewer" ]]; then
      copy_with_suffix "$build_dir/viewer/viewer" "$ROOT_DIR/src-tauri/linux-bin/fde-viewer" || true
    fi

    return 0
  fi

  cmake -S "$fde_source_dir" -B "$build_dir" -G Ninja "${cmake_args[@]}"

  local targets=(bitgen import map nlfiner pack place route sta)
  if [[ "$build_viewer" == "ON" ]]; then
    targets+=(FDE)
  fi
  cmake --build "$build_dir" --target "${targets[@]}" -j"$(cpu_count)"

  copy_with_suffix "$build_dir/bitgen/bitgen$exe_suffix" "$BIN_DIR/fde-cli/bitgen-$target_triple$exe_suffix" || true
  copy_with_suffix "$build_dir/vl2xml/import$exe_suffix" "$BIN_DIR/fde-cli/import-$target_triple$exe_suffix" || true
  copy_with_suffix "$build_dir/mapping/map$exe_suffix" "$BIN_DIR/fde-cli/map-$target_triple$exe_suffix" || true
  copy_with_suffix "$build_dir/NLFiner/nlfiner$exe_suffix" "$BIN_DIR/fde-cli/nlfiner-$target_triple$exe_suffix" || true
  copy_with_suffix "$build_dir/packing/pack$exe_suffix" "$BIN_DIR/fde-cli/pack-$target_triple$exe_suffix" || true
  copy_with_suffix "$build_dir/placer/place$exe_suffix" "$BIN_DIR/fde-cli/place-$target_triple$exe_suffix" || true
  copy_with_suffix "$build_dir/router/route$exe_suffix" "$BIN_DIR/fde-cli/route-$target_triple$exe_suffix" || true
  copy_with_suffix "$build_dir/sta/sta$exe_suffix" "$BIN_DIR/fde-cli/sta-$target_triple$exe_suffix" || true

  if [[ "$build_viewer" == "ON" ]]; then
    mkdir -p "$ROOT_DIR/src-tauri/linux-bin"
    copy_with_suffix "$build_dir/viewer/FDE$exe_suffix" "$ROOT_DIR/src-tauri/linux-bin/fde-viewer$exe_suffix" || true

    if command -v patchelf >/dev/null 2>&1; then
      patchelf --set-rpath '$ORIGIN/../libs' "$ROOT_DIR/src-tauri/linux-bin/fde-viewer$exe_suffix" 2>/dev/null || true
    fi
  fi
}

prepare_windows_legacy_sidecars() {
  if [[ "$platform" != "windows" ]]; then
    return 0
  fi

  local required_legacy=(bitgen import map nlfiner pack place route sta)
  local has_all=1
  for name in "${required_legacy[@]}"; do
    if [[ ! -f "$BIN_DIR/fde-cli/$name-$target_triple$exe_suffix" ]]; then
      has_all=0
      break
    fi
  done
  for name in yosys yosys-abc; do
    if [[ ! -f "$BIN_DIR/$name-$target_triple$exe_suffix" ]]; then
      has_all=0
      break
    fi
  done
  if [[ "$has_all" -eq 1 ]]; then
    echo "Windows legacy sidecars already exist; skipping installer extraction."
    return 0
  fi

  local installer_url="${UFDE_WINDOWS_LEGACY_INSTALLER_URL:-https://github.com/0xtaruhi/ufde-next/releases/download/version/UFDE%2B_1.1.0_x64-setup.exe}"
  local seven_zip=""
  seven_zip="$(command -v 7z || command -v 7zz || true)"
  if [[ -z "$seven_zip" ]]; then
    echo "7z/7zz is required to extract the legacy Windows installer." >&2
    return 0
  fi

  local tmpdir installer
  tmpdir="$(mktemp -d)"
  installer="$tmpdir/ufde-legacy-setup.exe"
  echo "Downloading legacy Windows sidecars from $installer_url."
  curl -fL "$installer_url" -o "$installer"
  "$seven_zip" x -y -o"$tmpdir/out" "$installer" >/dev/null

  for name in "${required_legacy[@]}"; do
    copy_with_suffix "$tmpdir/out/$name.exe" "$BIN_DIR/fde-cli/$name-$target_triple$exe_suffix" || true
  done
  copy_with_suffix "$tmpdir/out/yosys.exe" "$BIN_DIR/yosys-$target_triple$exe_suffix" || true
  copy_with_suffix "$tmpdir/out/yosys-abc.exe" "$BIN_DIR/yosys-abc-$target_triple$exe_suffix" || true
}

prepare_yosys_from_path() {
  local has_all=1
  for name in yosys yosys-abc; do
    if [[ ! -f "$BIN_DIR/$name-$target_triple$exe_suffix" ]]; then
      has_all=0
      break
    fi
  done
  if [[ "$has_all" -eq 1 ]]; then
    echo "Yosys sidecars already exist; skipping Yosys copy."
    return 0
  fi

  local yosys_bin="${YOSYS_BIN:-}"
  local yosys_abc_bin="${YOSYS_ABC_BIN:-}"
  if [[ -z "$yosys_bin" ]]; then
    yosys_bin="$(command -v yosys || true)"
  fi
  if [[ -z "$yosys_abc_bin" ]]; then
    yosys_abc_bin="$(command -v yosys-abc || true)"
  fi

  if [[ -n "$yosys_bin" ]]; then
    copy_with_suffix "$yosys_bin" "$BIN_DIR/yosys-$target_triple$exe_suffix" || true
  fi
  if [[ -n "$yosys_abc_bin" ]]; then
    copy_with_suffix "$yosys_abc_bin" "$BIN_DIR/yosys-abc-$target_triple$exe_suffix" || true
  fi
}

prepare_macos_runtime() {
  if [[ "$platform" != "macos" ]]; then
    return 0
  fi

  "$ROOT_DIR/scripts/prepare-macos-viewer-runtime.sh" --target "$target_triple"
}

require_sidecars() {
  local missing=0
  local required_fde=(bitgen import map nlfiner pack place route sta viewer)
  local required_ip=(ip_generator img2mif)
  local required_root=(yosys yosys-abc)

  for name in "${required_fde[@]}"; do
    local path="$BIN_DIR/fde-cli/$name-$target_triple$exe_suffix"
    if [[ ! -f "$path" ]]; then
      echo "::error file=src-tauri/binaries/fde-cli/$name-$target_triple$exe_suffix::Missing required FDE sidecar for $target_triple." >&2
      missing=1
    fi
  done

  for name in "${required_ip[@]}"; do
    local path="$BIN_DIR/ip-generator/$name-$target_triple$exe_suffix"
    if [[ ! -f "$path" ]]; then
      echo "::error file=src-tauri/binaries/ip-generator/$name-$target_triple$exe_suffix::Missing required IP sidecar for $target_triple." >&2
      missing=1
    fi
  done

  for name in "${required_root[@]}"; do
    local path="$BIN_DIR/$name-$target_triple$exe_suffix"
    if [[ ! -f "$path" ]]; then
      echo "::error file=src-tauri/binaries/$name-$target_triple$exe_suffix::Missing required Yosys sidecar for $target_triple." >&2
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    cat >&2 <<EOF

Missing sidecars for $target_triple.

Fix one of these ways:
  1. Provide UFDE_SIDECAR_ARCHIVE_URL for this CI job.
  2. Set FDE_SOURCE_DIR and YOSYS_SOURCE_DIR to build from source on Linux/macOS.
  3. Commit or otherwise restore the required src-tauri/binaries files.

EOF
    exit 1
  fi
}

download_sidecar_archive
build_ip_tools
build_ip_generator
prepare_fde_from_source
prepare_windows_legacy_sidecars
prepare_yosys_from_path
prepare_macos_runtime
require_sidecars

echo "Prepared Tauri sidecars for $target_triple."
