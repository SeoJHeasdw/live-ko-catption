#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root"
runtime_pin="7fe450e19305b828c199d602c23a8337aaa1f03b"
archive_sha="a6861d549427f814dc591c439e08206f67ffaba0248344d421589abf18199e67"
source_parent="$project_root/.build/local-runtime-source"
source_root="$source_parent/llama.cpp-$runtime_pin"
archive_path="$source_parent/llama-$runtime_pin.tar.gz"
tool_root="$project_root/.build/tools/local-runtime"
output_root="$project_root/.build/local-runtime"
build_root="$project_root/.build/local-runtime-build"
mkdir -p "$source_parent" "$output_root"

# Download build inputs only. The resulting runtime has no HTTP or server code.
if [[ ! -f "$archive_path" ]]; then
    curl --fail --location --retry 3 --silent --show-error \
        "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$runtime_pin" -o "$archive_path.part"
    mv "$archive_path.part" "$archive_path"
fi
actual_sha="$(shasum -a 256 "$archive_path" | cut -d ' ' -f 1)"
if [[ "$actual_sha" != "$archive_sha" ]]; then
    print -u2 -r -- "Pinned llama.cpp archive checksum did not match."
    exit 1
fi
if [[ ! -f "$source_root/include/llama.h" ]]; then
    tar -xzf "$archive_path" -C "$source_parent"
fi
if [[ ! -x "$tool_root/bin/cmake" || ! -x "$tool_root/bin/ninja" ]]; then
    python3 -m venv "$tool_root"
    "$tool_root/bin/python" -m pip install --disable-pip-version-check cmake==4.1.2 ninja==1.13.0
fi
"$tool_root/bin/cmake" -S "$project_root/Runtime" -B "$build_root" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$tool_root/bin/ninja" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.4 \
    -DCMAKE_OSX_SYSROOT="$(xcrun --show-sdk-path)" \
    -DLC_LLAMA_SOURCE="$source_root" \
    -DLC_OUTPUT_DIRECTORY="$output_root" \
    -DLLAMA_BUILD_COMMIT="$runtime_pin" -DLLAMA_BUILD_NUMBER=11146
"$tool_root/bin/cmake" --build "$build_root" --target caption_local_translation caption-local-benchmark --parallel 6

# Static llama/ggml and embedded Metal leave only Apple system dependencies.
otool -L "$output_root/libcaption_local_translation.dylib"
if otool -L "$output_root/libcaption_local_translation.dylib" | tail -n +2 | rg '(/opt/|/usr/local/|\.build/|libllama|libggml)'; then
    print -u2 -r -- "Local runtime contains a nonportable dynamic dependency."
    exit 1
fi
codesign --force --sign - "$output_root/libcaption_local_translation.dylib"
codesign --force --sign - "$output_root/caption-local-benchmark"
print -r -- "Local runtime built: $output_root/libcaption_local_translation.dylib"
