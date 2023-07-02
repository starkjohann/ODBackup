import Cocoa
import Foundation

extension SettingsWindowController {

    @IBAction func helpBackupPaths(_ sender: Any?) {
        InfoWindowController.shared.showInfoText(backupPathsText)
    }

    @IBAction func helpExcludes(_ sender: Any?) {
        InfoWindowController.shared.showInfoText(excludesText)
    }

    @IBAction func helpDestinations(_ sender: Any?) {
        InfoWindowController.shared.showInfoText(destinationsText)
    }

    @IBAction func helpSelectionScript(_ sender: Any?) {
        InfoWindowController.shared.showInfoText(selectionScriptText)
    }

    @IBAction func helpSSHCommand(_ sender: Any?) {
        InfoWindowController.shared.showInfoText(sshCommandText)
    }

    @IBAction func helpSSHKey(_ sender: Any?) {
        InfoWindowController.shared.showInfoText(sshKeyText)
    }

}

// -----------------------------------------------------------------------------
// MARK: - Backup Paths
// -----------------------------------------------------------------------------

private let backupPathsText = """
Backup Paths

Backup paths are paths relative to the Data volume of your startup drive. You cannot back up items from other volumes because only this volume is snapshot-mounted.

When you choose an item via the open-dialog, any leading slashes and a prefix of /System/Volumes/Data is automatically removed.

To back up the entire Data volume, use the path "." (for current directory, without the quotation marks).
"""

// -----------------------------------------------------------------------------
// MARK: - Exclude Patterns
// -----------------------------------------------------------------------------

private let excludesText = """
Exclude Patterns

Items in this list represent patterns (as accepted by borg backup) which are excluded from the backup.

Again, items are specified with a path relative to the Data volume, so do not include a leading "/" character.

Borg match patterns are similar to shell style glob patterns ("*" represents any text, except the path separator "/"), but extends these patterns by the symbol "**", which matches any text including path separators.

The list you enter is extended by some hardcoded exclude patterns for file system administrative files and files which are protected by SIP.

Here is a list of suggested excludes. You can copy them from here and paste them into the table:

private/var/folders
Library/Caches
System/Library/Caches
Users/*/Library/Caches
Users/*/Library/Containers/*/Data/Library/Caches
.TemporaryItems
**/.TemporaryItems
.Trashes
**/.Trashes
**/.Trash

If you are software developer, you probably also want these items:

Applications/Xcode*.app
Users/*/Library/Developer/CoreSimulator
Users/*/Library/Developer/DeveloperDiskImages
Users/*/Library/Developer/XCTestDevices
Users/*/Library/Developer/Xcode/DocumentationCache
Users/*/Library/Developer/Xcode/UserData
Users/*/Library/Developer/Xcode/iOS Device Logs
Users/*/Library/Developer/Xcode/DerivedData

It probably does not make sense to include the Spotlight index in the backup, so you can also add this:

Users/*/Library/Metadata/CoreSpotlight
private/var/db/Spotlight-V100

Then there is this place where data about you is collected proactively. If you can live without, exclude it:

Users/*/Library/Biome/streams/restricted/ProactiveHarvesting/*

And finally the logs. macOS logs a lot of data and you get around 500MB worth of backup data every day from the logs alone. On the other hand, if your mac is compromised in some way, the logs may contain valuable traces. I would therefore recommend not to exclude them. However, if you really want to exclude them, here are the patterns:

private/var/db/diagnostics
private/var/db/uuidtext
"""

// -----------------------------------------------------------------------------
// MARK: - Destinations
// -----------------------------------------------------------------------------

private let destinationsText = """
Destinations

Here you configure where the backups will be stored. Borg can make backups to a local disk or via SSH to a remote server.

Each destination should have a descriptive name (the "Name" column). This is the name you use when you talk about it and how you refer to it in the destination selection script below.

The repository URL is a simple path for local disk backups (e.g. "/Volumes/MyBackupVolume/BorgRepository"), or has the form "user@server:repopath" for backups via SSH to a remote server. Ask the administrator of the backup server for the username and path.

Backups are encrypted with a pass phrase. This way you can make backups to a server which is under the control of an administrator you don't trust. Although the server's administrator has full access to all backup files, they cannot decrypt any information. Choose a long and secure pass phrase, you don't have to type it. BUT SAVE A COPY OF THE PASS PHRASE IN A SECURE PLACE! You will need it in case of a desaster, when all your data is gone and only your backup is left. ODBackup stores the pass phrase in your login keychain of macOS.
"""

// -----------------------------------------------------------------------------
// MARK: - Selection Script
// -----------------------------------------------------------------------------

private let selectionScriptText = """
Zsh Script Selecting Destination

It is recommended to make backups to more than one physical location so that you still have a backup when there is a fire in one location or the backup disk is stolen.

ODBackup allows you to choose the destination for automatic backups with a shell script. The script has the following environment variables available:

$WIFI_SSID ........... The name of your current Wifi netowrk
$SCHEDULED_DATTIME ... Date and time when the backup was scheduled

The date and time is given as "YYYY-MM-DD hh:mm:ss" format and represents the time which is configured, not when the script and backup actually runs.

The script may echo the following info to standard output:

  - The name of a destination as configured above.
  - The literal SKIP to skip this backup. Send reason for skipping to stderr.
  - The literal DEFER to defer this backup for a short while.

Here is an example script which makes backup to the "Home" location when in the "Home" network, and to "Office" when in the "Office" network. Except at night, then the backup is always made to "Office". If the computer is in neither of the two networks, the backup is skipped:

if [ $(date '+%H') -lt 4 ]; then
    # Make remote backups at night, even if at home
    if [ "$WIFI_SSID" = 'Home' -o "$WIFI_SSID" = 'Office' ]; then
		echo "Office"
		exit
    fi
else
    if [ "$WIFI_SSID" = 'Home' ]; then
		echo "Home"
		exit
    elif [ "$WIFI_SSID" = 'Office' ]; then
		echo "Office"
		exit
    fi
fi

echo "SKIP"
echo "Skipping backup because Wifi $WIFI_SSID is not known" >&2
"""

// -----------------------------------------------------------------------------
// MARK: - SSH Command
// -----------------------------------------------------------------------------

private let sshCommandText = """
SSH Command with Options

You may require special options to ssh in order to log in at the remote server. For instance, if your ssh server listens on port 1234 instead of the standard port 22, configure the SSH command to

/usr/bin/ssh -p 1234

If the default configuration is OK for you, leave the field blank.
"""

// -----------------------------------------------------------------------------
// MARK: - Public SSH Key
// -----------------------------------------------------------------------------

private let sshKeyText = """
Public SSH Key

The Secure Shell (SSH) uses public key cryptography to encrypt your connection. In order to log in at the server, you usually need a private/public key pair (your identity). The server's administrator adds your public key to a configuration file to allow your login.

If you already have a key pair which is allowed to access the server, import it with "Import Keys…". You need read-access to both, the public and the private key. You can choose either the public or private key in the open panel, the other key is loaded automatically.

If you don't already have a key pair, generate a new one with "Generate New Keys". If you already have a key imported or generated, a safety alert asks you whether to overwrite the existing keys.

In any case, the server administrator needs to know your public key. You can copy it from this text field.
"""
