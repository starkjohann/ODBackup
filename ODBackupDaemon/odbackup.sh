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

exitWithCode() {
    trap - EXIT # remove exit handler
    code="$1"
    if [ -n "$logfile" ]; then
        if [ "$code" != 0 ]; then
            log "exit code: $code"
            mv "$logfile" "$logbase.error.log"
        else
            mv "$logfile" "$logbase.log"
        fi
        # delete log files older than 30 days:
        find "$logdir" -type f -name '*.log' -mtime +30 -delete
        (   # mark log files from aborted runs as error
            cd "$logdir"
            for file in *.inprogress.log; do
                [ -f "$file" ] || continue
                newname="$(echo "$file" | sed -e 's/[.]inprogress[.]log$/.error.log/')"
                mv "$file" "$newname"
            done
        )
        sleep 1 # wait until background reader from stderrFifo has read all data
    fi
    # There seems to be a bug somewhere which prevents a clean exit when
    # caffeinate is still running. This bug cannot easily be reproduced with
    # a simple test script, so it's hard to track down. Just kill it to
    # get around the problem.
    if [ -n "$caffeinePID" ]; then
        kill $caffeinePID 2>/dev/null
    fi
    # We may be existing a subshell only, but the main script propagates our exit code.
    exit "$code"
}

mountSnapshot() {
    mkdir "$mountpoint" 2>/dev/null
    snapshotTag=$(/usr/bin/tmutil localsnapshot | grep -v 'NOTE:' | awk '{ print $NF }')
    if ! /sbin/mount_apfs -o nobrowse,rdonly -s "com.apple.TimeMachine.$snapshotTag.local" /System/Volumes/Data "$mountpoint"; then
        log "*** Error mounting snapshot"
        rmdir "$mountpoint"
        exitWithCode 1
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
        mkdir "$dir" || exitWithCode 1
        cd "$dir" || exitWithCode 1
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
        exitWithCode 1
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
        exitWithCode 1
    fi

    echo "mounting shapshot"    # progress message
    mountSnapshot

    if ! cd "$mountpoint"; then
        log "*** Error cd-ing into snapshot root"
        umountSnapshot
        exitWithCode 1
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
    # We want to provide progress information to our caller on a separate channel.
    # Unfortunately, borg does not allow us to specify a separate file descriptor
    # for progress output. We therefore split stderr into two streams. One (stdout)
    # receives progress info, the other (stderr) receives statistics and error
    # messages. We can distinguish between the two by the line separator. Progress
    # info is followed by a CR only, to overwrite previous progress info in Terminal.
    # Errors are followed or introduced by LF, as usual on Unix.
    # `awk` allows us to specify a line separator (`RS`) and we use CR so that
    # each progress update and all statistics/error info is in one line each. If
    # the line contains an LF, it must be statistics or error. Otherwise it must
    # be a progress update.
    # For our caller, we send progress updates to stdout and errors/statistics
    # finally to stderr. fd=3 is redirected to stdout at the end of the script.
    "$borg" create "::$timestamp" "$@" --progress --stats --exclude-caches "${ADDITIONAL_EXCLUDES[@]}" --one-file-system --checkpoint-interval 900 <<<"$passPhrase" 2>&1 \
        | awk -v RS="\r" '{if (index($0, "\n") == 0) { print $0 ; fflush() } else { print $0 > "/dev/stderr"; fflush("/dev/stderr")} }'
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
            "$borg" compact --progress --verbose 2>&1 \
                | awk -v RS="\r" '{if (index($0, "\n") == 0) { print $0 ; fflush() } else { print $0 > "/dev/stderr"; fflush("/dev/stderr")} }'
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
