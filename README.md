# What is ODBackup?

ODBackup is a GUI frontend for [borg backup](https://www.borgbackup.org). It has been tailored for the backup needs at Objective Development (hence the name) and is made available as Open Source under the GPLv3 because it may be useful for others as well.

# Why Borg Backup?

We have chosen Borg backup because:

- It supports almost all file metadata of macOS.
- Works with our infrastructure (ssh login to server).
- Is very well tested and considered reliable. (Not all backup software can restore the backups it made!)
- It is deduplicating, sends only things which have changed.
- Is available for macOS and Linux (we also have Linux machines).
- Is reasonably fast.

An other candidate was [restic](https://restic.net), but it does not support our existing ssh infrastructure. By the way: I can recommend [Backup Bouncer](https://github.com/MacLemon/Backup-Bouncer) for evaluating backup programs for the Mac, although it's a couple of years old now.


# Design Goals

ODBackup has been made with the following ideas in mind:

- Elaborate reports about current, past and future activity. Backups are all about trust, so it is important to report on everything the program does.
- Errors must not go unnoticed.
- Easy way to extract entire backups or subdirectories thereof.
- Schedule for automatic backups.
- Backup to multiple destinations with a flexible way to choose the destination of automatic backups. 
- Handling of ssh configuration without going to the command line.
- Drag and drop installation, no additional dependencies to install.
- As little complexity in the code as possible.
- No third party frameworks.


# First Steps

In order to play around with ODBackup, start it, open the settings window, go to section "What to Bacukup" and choose a folder to back up in "Backup Paths". The folder should have reasonable size so that it takes a while to watch it back up, but the backup should not fill your disk. One to 10 GB should be fine.

You don't need exclude patterns at this step, but you may add some. Click the help button for suggestions.

Then go to section "Destination" and add a new entry. Name it "Test" or similar and choose a local path as repository URL, e.g. `/tmp/Test`. Finally enter a pass phrase (stored in the macOS Keychain).

The "Zsh Script Selecting Destination" is not needed until you configure automatic backups.

Section "Schedule" is only needed for automatic backups and for deleting old backups. You don't need that now.

Section "Network" is also not needed yet because you have configured a local backup.

Then go to the menu and choose "Back Up Now > To Test" to start your backup. This may be the point where ODBackup asks for full disk access, which is required for making backups. The first backup attempt will fail because the repository is not yet initialized. ODBackup offers to initialize it. After initialization, the backup is automatically retried and should succeed.

After the first successful backup go to the menu and choose "Extract > From Test". Files are extracted to a subdirectory in `/tmp`, so you can play around without overwriting anything on your computer. Note that you can stop listing the files in the backup if the thing you want to restore is already visible.

# Configuring the Server

Although setting up ssh access with authentication via public key is pretty simple, just adding the client's key to the `authorized_keys` file is not secure. ODBackup must perform backups unattended and the authorization key can therefore not be encrypted or otherwise protected.

However, it is possible to limit ssh access on the server to just borg and to a particular directory. We use an `authorized_keys` entry like this:

```
no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty,command="borg serve --restrict-to-path User_Name" ssh-ed25519 TXZijgXufD9C3QDto3ttz8H2RuyQcnjNH+Gp0I7UIh6xu+ydWyJ2r7yweeMdK+KfQfKf user.name@example.com    
```

ODBackup uses an SSH key of its own, so it does not intefere with other ssh logins which may be configured for the root user.


# Credits

Artwork of the [app icon](https://www.iconfinder.com/icons/2142702/arrow_backup_clock_data_refresh_safe_save_icon) and the [status menu item](https://www.iconfinder.com/icons/1654351/arrow_backup_clock_data_refresh_safe_guardar_icon) is by Kirill Kazachek.
