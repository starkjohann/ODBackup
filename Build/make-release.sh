#!/bin/sh
# This script builds the product and outputs the path containing the build result
# to stdout. It can be used for automated builds.
#
# ### PREREQUISITES FOR RUNNING THIS SCRIPT ###
# - The CWD must be the working copy directory of the project

scheme="ODBackup"
target="ODBackup"
configuration='Release'

# All log messages of this script are written to /tmp/buildlog-<PID>.log
logFile="/tmp/buildlog-$$.log"

# The code below runs in a sub-shell because we pipe through `tee`. We therefore
# need to communicate results via a file. That's the purpose of `$resultFolderFile`.
resultFolderFile="/tmp/resultfolder-$$.txt"

{
    # --------------------------------------------------------------------------
    # Parse some of the target’s build settings.
    # --------------------------------------------------------------------------
    # We use `xcodebuild -target` instead of `xcodebuild -scheme` here, because the
    # latter delivers the build settings of all targets that are associated with this
    # scheme, but we are only interested in the build settings of the main target.
    variables="$(xcodebuild -target "$target" -configuration "$configuration" -showBuildSettings)"
    assignmentScript="$(echo "$variables" | sed -ne 's/^ *\([^ ]*\) *= *\(.*\)$/\1=\2/gp' \
        | grep -v '^UID=' \
        | while read line; do
            printf "%q\n" "$line"
        done)"
    # Import all build settings as variables. This makes them available for expansion
    # of entitlements files and similar.
    eval "$assignmentScript"

    # --------------------------------------------------------------------------
    # Clean the build directory
    # --------------------------------------------------------------------------
    # We cannot use "xcodebuild clean" here, because it seems to falsely assume
    # the build directory to be located at <working-copy-dir>/build. We therefore
    # determine the “build directory” by removing the last path component from
    # the `BUILD_DIR` build setting and then remove that entire directory manually.
    # BUILD_DIR = /Users/me/Library/Developer/Xcode/DerivedData/MyApplication-dtryuvbfooihzkedusplaigvmmjp/Build/Products
    echo "Build folder: $BUILD_DIR"
    if [ "$(echo "$BUILD_DIR" | wc -c)" -lt 45 ]; then
        echo "Build folder probably wrong, not deleting"
        exit 1
    fi
    rm -rf "$BUILD_DIR/../Intermediates.noindex"    # object files
    rm -rf "$BUILD_DIR"

    # --------------------------------------------------------------------------
    # Perform the actual build
    # --------------------------------------------------------------------------
    if ! xcodebuild -scheme "$scheme" -configuration "$configuration"; then
        echo "Build failed, aborting!"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # Post processing
    # --------------------------------------------------------------------------
    # Copy all build results to the result folder.
    resultFolder="$TARGET_BUILD_DIR"
    mv "$logFile" "$resultFolder/buildlog.log"

    echo "$resultFolder" > "$resultFolderFile"
} 2>&1 | tee "$logFile" >&2 # Ensure all output goes to stderr

cat "$resultFolderFile" 2>/dev/null
rm -f "$resultFolderFile"
