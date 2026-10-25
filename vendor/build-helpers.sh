#!/bin/zsh
# Builds the converters Elconvo carries inside the app, from their official sources, so nobody needs
# Homebrew and the App Store build can run them in its sandbox:
#   ffmpeg  an LGPL build (no GPL or non-free parts, as the App Store requires) with LAME (MP3), libvpx (VP8/VP9),
#           Opus and Vorbis, plus Apple's VideoToolbox (hardware H.264/HEVC) and AudioToolbox.
#   cwebp   from Google's libwebp, for WebP.
# Universal (Apple Silicon + Intel), statically linked, macOS 14+. Output: vendor/bin/ffmpeg, vendor/bin/cwebp,
# and vendor/licenses/. Takes a while; nothing is installed anywhere else.
set -euo pipefail
cd "$(dirname "$0")"
ROOT=$PWD
SRC=$ROOT/src
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$SRC" "$ROOT/bin" "$ROOT/licenses"

FFMPEG=7.1.1 LAME=3.100 VPX=1.15.0 OPUS=1.5.2 OGG=1.3.5 VORBIS=1.3.7 WEBP=1.5.0
fetch() {   # url, folder it unpacks to
    [[ -d "$SRC/$2" ]] && return
    echo "· downloading $2"
    curl -fsSL "$1" -o "$SRC/$2.tar"
    tar -xf "$SRC/$2.tar" -C "$SRC"
    rm "$SRC/$2.tar"
}
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG.tar.xz" "ffmpeg-$FFMPEG"
fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME/lame-$LAME.tar.gz" "lame-$LAME"
fetch "https://github.com/webmproject/libvpx/archive/refs/tags/v$VPX.tar.gz" "libvpx-$VPX"
fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS.tar.gz" "opus-$OPUS"
fetch "https://downloads.xiph.org/releases/ogg/libogg-$OGG.tar.gz" "libogg-$OGG"
fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS.tar.gz" "libvorbis-$VORBIS"
fetch "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$WEBP.tar.gz" "libwebp-$WEBP"
# libvorbis 1.3.7 still passes an old linker flag on macOS that today's linker rejects.
sed -i '' 's/-force_cpusubtype_ALL//g' "$SRC/libvorbis-$VORBIS/configure"

for ARCH in arm64 x86_64; do
    PREFIX=$ROOT/build/$ARCH
    HOST=$([[ $ARCH == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
    export CC="clang -arch $ARCH -mmacosx-version-min=14.0" CXX="clang++ -arch $ARCH -mmacosx-version-min=14.0"
    export CFLAGS="-O2" LDFLAGS="-arch $ARCH -mmacosx-version-min=14.0"
    # Only the libraries built here, never Homebrew's.
    export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
    mkdir -p "$PREFIX"
    autotools() {   # folder, extra configure flags…
        local dir=$1; shift
        [[ -f "$PREFIX/.done-$dir" ]] && return
        echo "· $dir ($ARCH)"
        (cd "$SRC/$dir" && make distclean >/dev/null 2>&1 || true
         ./configure --host=$HOST --prefix="$PREFIX" --disable-shared --enable-static "$@" >/dev/null
         make -j$JOBS >/dev/null && make install >/dev/null)
        touch "$PREFIX/.done-$dir"
    }
    autotools "lame-$LAME" --disable-frontend --disable-decoder
    autotools "opus-$OPUS" --disable-doc --disable-extra-programs
    autotools "libogg-$OGG"
    autotools "libvorbis-$VORBIS" --with-ogg="$PREFIX" --disable-examples --disable-docs
    autotools "libwebp-$WEBP" --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic

    if [[ ! -f "$PREFIX/.done-vpx" ]]; then
        echo "· libvpx ($ARCH)"
        # Apple Silicon gets libvpx's NEON code; Intel builds plain C, which needs no extra assembler.
        TARGET=$([[ $ARCH == arm64 ]] && echo arm64-darwin23-gcc || echo generic-gnu)
        (cd "$SRC/libvpx-$VPX" && make distclean >/dev/null 2>&1 || true
         ./configure --target=$TARGET --prefix="$PREFIX" --disable-examples --disable-tools --disable-docs \
            --disable-unit-tests --enable-pic --enable-vp9-highbitdepth >/dev/null
         make -j$JOBS >/dev/null && make install >/dev/null)
        touch "$PREFIX/.done-vpx"
    fi

    if [[ ! -f "$PREFIX/.done-ffmpeg" ]]; then
        echo "· ffmpeg ($ARCH)"
        ASM=$([[ $ARCH == x86_64 ]] && echo --disable-x86asm || echo "")
        (cd "$SRC/ffmpeg-$FFMPEG" && make distclean >/dev/null 2>&1 || true
         ./configure --prefix="$PREFIX" --arch=$ARCH --target-os=darwin --enable-cross-compile --cc="$CC" $ASM \
            --pkg-config=pkg-config --pkg-config-flags=--static \
            --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
            --disable-autodetect --disable-doc --disable-ffplay --disable-network --disable-debug \
            --disable-shared --enable-static \
            --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
            --enable-libmp3lame --enable-libvpx --enable-libopus --enable-libvorbis >/dev/null
         make -j$JOBS >/dev/null && make install >/dev/null)
        touch "$PREFIX/.done-ffmpeg"
    fi
done

lipo -create build/arm64/bin/ffmpeg build/x86_64/bin/ffmpeg -output bin/ffmpeg
lipo -create build/arm64/bin/cwebp build/x86_64/bin/cwebp -output bin/cwebp
cp "$SRC/ffmpeg-$FFMPEG/COPYING.LGPLv2.1" licenses/ffmpeg-LGPL-2.1.txt
cp "$SRC/lame-$LAME/COPYING" licenses/lame-LGPL.txt
cp "$SRC/libvpx-$VPX/LICENSE" licenses/libvpx-BSD.txt
cp "$SRC/opus-$OPUS/COPYING" licenses/opus-BSD.txt
cp "$SRC/libogg-$OGG/COPYING" licenses/libogg-BSD.txt
cp "$SRC/libvorbis-$VORBIS/COPYING" licenses/libvorbis-BSD.txt
cp "$SRC/libwebp-$WEBP/COPYING" licenses/libwebp-BSD.txt
cat > licenses/README.txt <<TXT
Elconvo includes ffmpeg $FFMPEG (LGPL 2.1, built without GPL or non-free parts), LAME $LAME (LGPL),
libvpx $VPX, Opus $OPUS, libogg $OGG, libvorbis $VORBIS and libwebp $WEBP (BSD-style licenses).
Their source code is at the projects' official sites; the exact build is vendor/build-helpers.sh in
https://github.com/eladitz/elconvo, which rebuilds them from that source.
TXT
echo "Done: $(du -h bin/ffmpeg | cut -f1) ffmpeg, $(du -h bin/cwebp | cut -f1) cwebp"
bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "libmp3lame|libvpx-vp9|libopus|libvorbis|h264_videotoolbox|hevc_videotoolbox" | awk '{print "  " $2}'
