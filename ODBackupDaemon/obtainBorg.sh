#!/bin/sh -e

# This script is made to be called as an Xcode build phase. It checks whether we have
# already downloaded borg to our cache, downloads it on demand and copies the extracted
# archive to the bundle's Contents/Frameworks directory.

url="https://github.com/borgbackup/borg/releases/download/1.2.4/borg-macos64.tgz"
cacheDir=./Download-Cache

mkdir -p "$cacheDir" && cd "$cacheDir"
version="$(basename "$(dirname "$url")")"
cacheFile="$(basename "$url" .tgz)-$version.tgz"
destination="$CODESIGNING_FOLDER_PATH/Contents/Resources"
rm -rf "$destination"/borg*

if [ ! -s "$cacheFile" ]; then
    curl -L "$url" >"$cacheFile"
fi

mkdir -p "$destination"
tar -C "$destination" -xzf "$cacheFile"
cd "$destination"
mv borg* borg
xattr -r -d com.apple.quarantine borg

codesign -f -s "$EXPANDED_CODE_SIGN_IDENTITY" -o runtime $OTHER_CODE_SIGN_FLAGS $(find borg -type f \( -perm +111 -o -name '*.dylib' -o -name '*.so' \) -print)
