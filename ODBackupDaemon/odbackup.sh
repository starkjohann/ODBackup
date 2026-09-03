#!/bin/sh -o pipefail

# Calling conventions:
# set the following environment variables:
# PRUNE_OPTIONS ..... options to prune repo
# BORG_REPO ......... the repo to work on
# REPO_NAME ......... clear text name used in log file
# BORG_RSH .......... ssh command to use
#
# Use the following commands. All arguments are passed to borg.
# init
# backup
# list
# extract
# testaccess
# log

if [ $(id -u) != 0 ]; then
    echo "$0 must be run as root!" >&2
    exit 1
fi

# `jq` is part of macOS since version 15, which is our minimum requirement.
if [ ! -x /usr/bin/jq ]; then
    echo "$0 requires /usr/bin/jq (macOS 15 or later)!" >&2
    exit 1
fi

# Try to read a pass phrase from stdin. If none is required/provided, we should
# reach EOF.
passPhrase=`cat`

export BORG_PASSCOMMAND=/bin/cat    # pass phrase via stdin

if [ -z "$BORG_RSH" ]; then
    unset BORG_RSH
fi

mountpoint='/Volumes/ODBackupDataDiskSnapshot'

if [ -n "$BORG_EXECUTABLE" ]; then
    borg="$BORG_EXECUTABLE"
else
    borg=borg
fi

log() {
    echo "$@" >&2
}

isodate() {
    date '+%Y-%m-%d %H:%M:%S'
}

# We want to provide progress information to our caller on a separate channel.
# Unfortunately, borg does not allow us to specify a separate file descriptor
# for progress output. We therefore merge borg's stdout and stderr into this
# filter and split the result into two streams: our stdout receives progress
# info, our stderr receives statistics and error messages.
# We used to tell the two apart by their line terminator (CR for progress info,
# which overwrites the previous progress info in Terminal, LF for everything
# else), but borg 1.4 no longer terminates the progress line of `borg create`
# with CR when its stderr is not a terminal -- which is the case here. We
# therefore run borg with `--log-json`: it then writes one JSON object per line,
# each tagged with a `type` which tells us reliably which channel it belongs to.
# `jq` decodes the JSON (borg escapes everything non-ASCII as \uXXXX) and tags
# each line with the channel it goes to. We pass `--unbuffered` so that progress
# info reaches our caller while the backup is running, and `-R` so that a line
# which is not JSON at all -- a crash report from borg, say -- is passed through
# instead of aborting `jq`.
# `awk` then formats the byte counts the way borg would and sends the result to
# stdout or stderr. We keep borg's own wording for progress messages, because
# our caller recognizes "Initializing cache transaction: Reading files" as the
# start of a checkpoint.
# For our caller, we send progress updates to stdout and errors/statistics
# finally to stderr. fd=3 is redirected to stdout at the end of the script.
splitProgressFromDiagnostics() {
    /usr/bin/jq --unbuffered -R -r '
        def clean: (. // "") | gsub("[\r\n]"; " ");
        (fromjson? // .) as $record
        | if ($record | type) != "object" then
              "D\t\(.)"                     # not JSON, e.g. a crash report from borg
          elif $record.type == "archive_progress" then
              if $record.finished == true then
                  empty                     # borg clears its progress display
              else
                  "A\t\($record.original_size)\t\($record.compressed_size)\t\($record.deduplicated_size)\t\($record.nfiles)\t\($record.path | clean)"
              end
          elif $record.type == "progress_message" or $record.type == "progress_percent" then
              if ($record.message // "") == "" then empty else "P\t\($record.message | clean)" end
          elif $record.type == "log_message" then
              "D\t\($record.message | clean)"
          elif $record.type == "file_status" then
              "D\t\($record.status) \($record.path | clean)"
          else
              "D\t\(.)"                     # unknown record type, do not lose it
          end
    ' | awk '
        BEGIN { FS = "\t" }

        # Formats a byte count the way borg does in its human readable output.
        function formatSize(bytes,   units, i, value) {
            bytes += 0      # make sure we compare numerically, not as strings
            if (bytes < 1000)
                return sprintf("%d B", bytes)
            split("k M G T P E Z Y", units, " ")
            value = bytes
            for (i = 1; i < 8; i++) {
                value = value / 1000
                if (value < 1000)
                    return sprintf("%.2f %sB", value, units[i])
            }
            return sprintf("%.2f %sB", value / 1000, units[8])
        }

        function emitProgress(line) { print line; fflush() }
        function emitDiagnostics(line) { print line > "/dev/stderr"; fflush("/dev/stderr") }

        {
            if ($1 == "A") {        # progress of `borg create`, still in separate fields
                path = $6
                for (i = 7; i <= NF; i++)
                    path = path "\t" $i     # a file name may contain tabs
                emitProgress(sprintf("%s O %s C %s D %d N %s", formatSize($2), formatSize($3), formatSize($4), $5, path))
            } else {
                payload = substr($0, index($0, "\t") + 1)
                if ($1 == "P")
                    emitProgress(payload)
                else
                    emitDiagnostics(payload)
            }
        }
    '
}

exitWithCode() {
    trap - EXIT # remove exit handler
    code="$1"
    if [ -n "$logfile" ]; then
        # borg uses exit code 1 for warnings and 2 (and above) for errors.
        # We use the same convention for errors detected by this script.
        if [ "$code" = 0 ]; then
            mv "$logfile" "$logbase.log"
        elif [ "$code" = 1 ]; then
            log "exit code: $code"
            mv "$logfile" "$logbase.warning.log"
        else
            log "exit code: $code"
            mv "$logfile" "$logbase.error.log"
        fi
        # delete log files older than 30 days:
        find "$logdir" -type f -name '*.log' -mtime +30 -delete
        # Since there can be only one backup process running at a time,
        # if this is a backup run, all "in progress" logs must be from aborted
        # backups, so mark them as error.
        if [ "$cmd" = backup ]; then
            cd "$logdir"
            for file in *.inprogress.log; do
                [ -f "$file" ] || continue
                newname="$(echo "$file" | sed -e 's/[.]inprogress[.]log$/.error.log/')"
                mv "$file" "$newname"
            done
        fi
        sleep 1 # wait until background reader from stderrFifo has read all data
    fi
    # There seems to be a bug somewhere which prevents a clean exit when
    # caffeinate is still running. This bug cannot easily be reproduced with
    # a simple test script, so it's hard to track down. Just kill it to
    # get around the problem.
    if [ -n "$caffeinePID" ]; then
        kill $caffeinePID 2>/dev/null
    fi
    # We may be exiting a subshell only, but the main script propagates our exit code.
    exit "$code"
}

mountSnapshot() {
    mkdir "$mountpoint" 2>/dev/null
    snapshotTag=$(/usr/bin/tmutil localsnapshot | grep -v 'NOTE:' | awk '{ print $NF }')
    if ! /sbin/mount_apfs -o nobrowse,rdonly -s "com.apple.TimeMachine.$snapshotTag.local" /System/Volumes/Data "$mountpoint"; then
        log "*** Error mounting snapshot"
        rmdir "$mountpoint"
        exitWithCode 2
    fi
}

umountSnapshot() {
    cd /
    /sbin/umount -f "$mountpoint"
    rmdir "$mountpoint" 2>/dev/null
    if [ -n "$snapshotTag" ]; then
        /usr/bin/tmutil deletelocalsnapshots "$snapshotTag"
    fi
}

cleanupWhenKilled() {
    # If this script is killed, our borg child somehow escapes from being killed with us.
    # We therefore catch the signal, kill all borg child processes and termiante.
    log 'Killed by signal'
    pkill -P $$ -x "$(basename "$borg")"
    # When catching a signal with `trap` and this is an extract or list
    # instance, don't unmount so that we don't interfere with running backups.
    if [ "$cmd" = backup ]; then
        umountSnapshot 2>/dev/null
    fi
    exitWithCode 143
}

trap "cleanupWhenKilled" EXIT

borgDryRun() {
    echo "Arguments: $@"
    echo "Stdin:"
    cat
    echo "Environment:"
    env
}

cmd="$1"
shift
case "$cmd" in
    init)
        "$borg" init -e repokey "$@" <<<"$passPhrase"
        exitWithCode $?
    ;;
    backup)
        # handled below
    ;;
    log)
        # handled below
    ;;
    list)
        "$borg" list "$@" <<<"$passPhrase"
        exitWithCode $?
    ;;
    extract)
        # We might want to provide progress info here as well
        dir="/tmp/ODBackup-extract-$$-$RANDOM"
        mkdir "$dir" || exitWithCode 2
        cd "$dir" || exitWithCode 2
        open "$dir" # open Directory in Finder
        #
        "$borg" extract "$@" --umask 0022 <<<"$passPhrase"
        rval=$?
        open "$dir" # open Directory in Finder
        exitWithCode "$rval"
    ;;
    testaccess)
        # If anybody finds a better way to check for full disk access, please tell us!
        mountpoint="$(mktemp -d)"   # do not interfere with possibly running backup
        mountSnapshot
        umountSnapshot
        exitWithCode 0
    ;;
    *)
        self=$(basename $0)
        log "Usage:"
        log "$self init|backup|list|extract|testaccess <args...>"
        exitWithCode 2
    ;;
esac

# Fallthrough only for case `backup` and `log`

timestamp=$(date '+%Y-%m-%d_%H%M%S')
logdir=/var/log/ODBackup
# Characters we want to avoid in log file names: [\0- /:\\]
normalizedRepoName="$(echo "$REPO_NAME" | tr -d '\n' | tr '\0- /:\\' '_')"
logbase="$logdir"/$timestamp."$normalizedRepoName"
logfile="$logbase.inprogress.log"

stderrFifo="$(mktemp -u)"
mkfifo -m 0600 "$stderrFifo"    # will be deleted immediately below
tee "$logfile" <"$stderrFifo" >&2 & # send stderr output to log file and real stderr
{
    rm -f "$stderrFifo"   # no longer needed
    mkdir -p "$logdir"

    if [ "$cmd" == log ]; then
        log "$2"    # Our only task is to log something to a logfile and exit with a given exit code
        exitWithCode "$1"
    fi

    caffeinate -s -w $$ &  # prevent system sleep while backup is running
    caffeinePID=$!

    log "Backup to $BORG_REPO"
    log
    rmdir "$mountpoint" 2>/dev/null # remove if stale and empty
    if [ -d "$mountpoint" ]; then
        log "*** Previous backup currently in progress -- skipping"
        exitWithCode 1 # skipping is a warning, not an error
    fi

    echo "mounting shapshot"    # progress message
    mountSnapshot

    if ! cd "$mountpoint"; then
        log "*** Error cd-ing into snapshot root"
        umountSnapshot
        exitWithCode 2
    fi

    ADDITIONAL_EXCLUDES=(
        -e ".fseventsd"
        -e ".Spotlight-V100"
        -e '.HFS+ Private Directory Data*'
        -e ".DocumentRevisions-V100"
        -e "private/var/vm"
        -e "private/var/db/ConfigurationProfiles"
        -e "private/var/db/fpsd/dvp"
    )


    echo "starting borg" # progress message
    log "### Starting backup of / at" "$(isodate)"
    "$borg" create "::$timestamp" "$@" --progress --log-json --stats --exclude-caches "${ADDITIONAL_EXCLUDES[@]}" --one-file-system --checkpoint-interval 900 <<<"$passPhrase" 2>&1 \
        | splitProgressFromDiagnostics
    borgExitCode=$? # we have `set -o pipefail`
    log "### Ready at" "$(isodate)"

    umountSnapshot

    if [ "$borgExitCode" = 0 ]; then
        log '### Pruning Repository at' "$(isodate)"
        echo "pruning repository"   # progress message
        "$borg" prune $PRUNE_OPTIONS <<<"$passPhrase"
        log '### Ready pruning at' "$(isodate)"

        # Check whether we should compact the repo
        timestampFile="$logdir/.lastCompaction.$normalizedRepoName"
        currentHour=$(date "+%H")
        now="$(date +"%s %F %H:%M:%S")"
        lastCompactionDate="$(echo 0 | cat "$timestampFile" - 2>/dev/null)"
        age="$(expr ${now%% *} - ${lastCompactionDate%% *} 2>/dev/null)"
        # We try to do compaction at night. If we can't get it done for a while,
        # do it anyway.
        if [ "$currentHour" -ge 2 -a "$currentHour" -lt 6 ]; then
            maxAge=$((86400 * 28))  # compact every 28 days at night
        else
            maxAge=$((86400 * 31))  # compact every 31 days during daytime
        fi
        if [ -z "$age" -o "$age" -gt "$maxAge" ]; then
            log '### Compacting Repository at' "$(isodate)"
            echo "compacting repository"   # progress message
            "$borg" compact --progress --log-json --verbose 2>&1 \
                | splitProgressFromDiagnostics
            compactExitCode=$?  # we have `set -o pipefail`
            log '### Ready compacting at' "$(isodate)"
            if [ "$compactExitCode" = 0 ]; then
                echo "$now" >"$timestampFile"
            fi
        fi
    fi

    exitWithCode "$borgExitCode"

} 2>"$stderrFifo"

# We cannot reach this point because all code paths above call exitWithCode.
# However, if for whatever reason we arrive here, prevent calling the exit handler
# in a loop and exit with the status of the last command.
rval=$?
trap - EXIT
exit "$rval"
