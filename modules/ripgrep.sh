#!/usr/bin/env bash
# modules/ripgrep.sh - ripgrep binary for @vscode/ripgrep(-universal)
#
# Which ripgrep? The one upstream ships. VS Code depends on
# @vscode/ripgrep-universal (>= 1.140) or @vscode/ripgrep (older). Both are
# built from microsoft/vscode-ripgrep, which pins a microsoft/ripgrep-prebuilt
# release, whose config.json names the BurntSushi/ripgrep tag. We follow that
# chain and fall back to VSX_RIPGREP_FALLBACK_TAG if any link is missing.
#
# AIX notes:
#   * memmap2's madvise() call needs a caddr_t cast on AIX; we vendor the
#     locked memmap2 version and patch it through [patch.crates-io].
#   * Built with --features pcre2 (bundled PCRE2, JIT works on ppc64).
#   * The MSRV of the ripgrep tag is checked against the host rustc first so
#     a too-old toolchain fails with a clear message instead of a cargo wall.
#
# Where does the binary go? ripgrep-universal resolves
# bin/<process.platform>-<process.arch>/rg at load time; with the platform
# override active that is linux-ppc64, without it aix-ppc64. We install both.

_rg_fetch() { curl -fsSL --retry 2 "$1" 2>/dev/null || true; }

mod_ripgrep_wanted() {
    local server=$1 pkgver tag prebuilt js
    pkgver=$(server_bundled_version "$server" "@vscode/ripgrep-universal")
    if [[ -n "$pkgver" ]]; then
        js=$(_rg_fetch "https://raw.githubusercontent.com/microsoft/vscode-ripgrep/v$pkgver/build/platforms.js")
        prebuilt=$(grep -E "^const VERSION *= *'" <<<"$js" | head -1 | cut -d"'" -f2)
    else
        pkgver=$(server_bundled_version "$server" "@vscode/ripgrep")
        [[ -n "$pkgver" ]] || return 0
        js=$(_rg_fetch "https://raw.githubusercontent.com/microsoft/vscode-ripgrep/v$pkgver/lib/postinstall.js")
        prebuilt=$(grep -E "^const VERSION *= *'" <<<"$js" | head -1 | cut -d"'" -f2)
    fi
    if [[ -n "$prebuilt" ]]; then
        tag=$(_rg_fetch "https://raw.githubusercontent.com/microsoft/ripgrep-prebuilt/$prebuilt/config.json" | jpy 'd.get("ripgrepTag","")' 2>/dev/null || true)
        # Older prebuilt tags have no config.json: v13.0.0-10 -> 13.0.0
        [[ -n "$tag" ]] || tag=$(sed -E 's/^v//; s/-[0-9]+$//' <<<"$prebuilt")
    fi
    if [[ -z "$tag" ]]; then
        warn "ripgrep: could not resolve upstream ripgrep tag for package $pkgver; using fallback $VSX_RIPGREP_FALLBACK_TAG"
        tag="$VSX_RIPGREP_FALLBACK_TAG"
    fi
    printf '%s\n' "$tag"
}

mod_ripgrep_cache_key() { printf '%s-rustc%s\n' "$1" "$VSX_RUSTC_VERSION"; }

mod_ripgrep_build() {
    local tag=$1 out=$2
    env_require_rust
    export CC=gcc CXX=g++
    git_clone_tag "$VSX_REPO_RIPGREP" "$tag" src
    cd src || return 1
    rust_check_msrv Cargo.toml

    local mm
    mm=$(awk '/^name = "memmap2"$/ {f=1; next} f && /^version = / {print $3; f=0; exit}' Cargo.lock | tr -d '"')
    [[ -n "$mm" ]] || { echo "ERROR: memmap2 not found in Cargo.lock" >&2; return 1; }
    echo "vendoring memmap2 $mm for the AIX madvise fix"
    mkdir -p vendor
    git clone -q --depth 1 --branch "v$mm" "$VSX_REPO_MEMMAP2" vendor/memmap2
    if grep -q 'madvise(self.ptr.offset(offset), len, advice)' vendor/memmap2/src/unix.rs; then
        sed -i 's/madvise(self\.ptr\.offset(offset), len, advice)/madvise(self.ptr.offset(offset) as libc::caddr_t, len, advice)/' vendor/memmap2/src/unix.rs
        printf '\n[patch.crates-io]\nmemmap2 = { path = "vendor/memmap2" }\n' >>Cargo.toml
    else
        echo "memmap2 $mm: madvise pattern not found; building without the patch"
        rm -rf vendor
    fi

    cargo build --release --features pcre2
    ./target/release/rg --version
    strip -X64 target/release/rg 2>/dev/null || true
    cp target/release/rg "$out/rg"
    chmod 755 "$out/rg"
}

mod_ripgrep_install() {
    local out=$1 server=$2 base
    if [[ -d "$server/node_modules/@vscode/ripgrep-universal" ]]; then
        base="$server/node_modules/@vscode/ripgrep-universal/bin"
        install_file "$out/rg" "$base/aix-ppc64/rg"
        install_file "$out/rg" "$base/linux-ppc64/rg"
        # Drop foreign binaries; they can never run here.
        local d
        for d in "$base"/*/; do
            case "$(basename "$d")" in aix-ppc64|linux-ppc64) ;; *) rm -rf "$d" ;; esac
        done
    elif [[ -d "$server/node_modules/@vscode/ripgrep" ]]; then
        install_file "$out/rg" "$server/node_modules/@vscode/ripgrep/bin/rg"
    else
        warn "ripgrep: no @vscode/ripgrep* package in server; nothing to install"
    fi
}

mod_ripgrep_note() { echo "built from BurntSushi/ripgrep tag with pcre2; memmap2 AIX madvise patch"; }
