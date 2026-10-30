# ATA drive security

Volume → Drive Security operates on external USB-connected ATA disks using the supplied `atasec` transport. The adapter must support ATA pass-through. The app unmounts the selected disk and captures its USB device for the operation; finish file transfers and keep the adapter connected. Unsupported multi-disk adapters are rejected when multiple disks are detected on the same USB device.

The app does not decrypt EEPROM backups or include EEPROM decryption keys. Extract your HDD key separately.

If a device scan fails, the app inspects ATA status when possible and offers Drive Security if the drive reports it is locked. Choose one saved key or enter it manually; keys are never tried automatically. To save a named HDD key, select the Keychain option before a successful Set Password or Unlock. Manage and delete keys in Drive Security. The Keychain belongs to your current macOS user. Wrong passwords consume limited attempts. After unlock, select the device again.

1. Choose the external disk and select **Inspect Device**. Check its displayed model and serial.
2. Enter the 16-byte HDD key in hex or a direct ATA password (text or hex). The HDD key must be the console's **current** key. Extract it separately from your own backup.
3. Use **Show Password** to inspect the derived value, **Set Password** to enable security, **Unlock** for an already locked drive, or **Remove Password** to disable security. A confirmation identifies the selected model and serial.
4. For an HDD key, the password uses HMAC-SHA1 of the target's ATA model and serial, padded with zeroes to 32 bytes; maximum security and the user password are selected. The standard order is model then serial. The optional legacy serial-first order is an alternative; wrong passwords consume limited attempts.

A newly set user password normally causes the drive to lock on the next power cycle, not immediately. An unlock lasts only until power is removed. A stock console generally needs the drive's user password enabled and derived from its current HDD key. Do not remove a password from an original drive unless you have a separate recovery plan. Maximum security prevents normal master-password unlock and may leave only destructive erase if the correct user password is lost.

Direct passwords support UTF-8 or exact hex bytes up to 32 bytes, user or master, and high or maximum security for setting a password. HDD key mode always use the user password and maximum security. Passwords go through private IPC and stdin, not process arguments or log output. An explicitly displayed derived password is sensitive; do not share it.

Before changing security, the helper re-reads ATA IDENTIFY, compares the target's model/serial fingerprint to the reviewed drive, and rejects unsupported, frozen, exhausted or incompatible security states. USB short transfers and errors are rejected. Commands are not automatically retried. If a command or post-check fails, the drive's actual state may be unknown; inspect it before taking further action. The outcome is confirmed by a new IDENTIFY response where the standard exposes a status flag. A master password's actual value cannot be read back, so the tool can only report command acceptance.

This integration requires further physical-device testing. The supplied standalone transport was reported tested on macOS with a SATA SSD. The user reported the integrated workflow worked on their Mac and SSD. Results on other adapters and systems may differ; the console-specific password has not been independently tested in this environment. No Mac build or hardware lock was performed here. Preserve the original drive and backup until you have verified the new drive works.

The GUI selects a whole disk reported by `diskutil`. Some locked drives or USB bridges do not expose a disk node to macOS until unlocked; in that situation the GUI cannot select them. The separately supplied standalone transport's USB-device selection may still work. The application rejects other external devices whose USB relationship cannot be verified, and adapters that expose multiple disks; disconnect other external storage if necessary.
