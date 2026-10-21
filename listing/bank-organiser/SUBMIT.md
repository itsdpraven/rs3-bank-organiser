# Submitting Bank Organiser to mod.io

Follows Jagex's [submission process](https://developer.runescape.com/rs/submission/process.html).
Everything to paste is in `dist/LISTING.md` after packaging ([`LISTING.md`](LISTING.md) with the email filled in).

## Before you start

- [ ] `tools/contact-email.txt` holds the plugin's contact email (it isn't in the
      public repository; the packaging script puts it into the upload and
      writes `dist/LISTING.md`, the listing text with the email filled in).
- [ ] The latest build has been tried in the game (moderators expect working
      files and say not to use moderation as testing).
- [ ] The upload is built:
      `powershell -ExecutionPolicy Bypass -File tools/package-bank-organiser.ps1`
      → `dist/bank-organiser-<version>.zip` (only `main.lua`, `plugin.json` and `src/`).

## Step 1: Plugin profile

On the RuneScape page on mod.io, click **Add plugin** (top right).

| Field | Value |
|---|---|
| Plugin name | `Bank Organiser` |
| Summary | the *Summary* line from `LISTING.md` (ASCII, 10-250 characters) |
| Plugin listing image | `listing-image.png` (1920x1080, 16:9, 1.4 MB) |
| Homepage | `https://github.com/itsdpraven/rs3-bank-organiser` |
| Profile URL | `bank-organiser` |
| Allow comments | your choice |
| Allow dependents | off (nothing depends on it) |
| Allow to be added to collections | on |
| Description | everything from *Description* to the end of *Data Protection (case 1)* in `LISTING.md` |
| Tags | none needed (the plugin requests no permissions) |
| Visibility | **Hidden** until you're ready for players to see it |

The description must keep its four required sections: Email, EULA,
Permissions ("This plugin requests no permissions") and Data Protection (case 1).
To keep the email out of public view, add at the end of the description:
`For Jagex: I request that the supplied email is hidden from public view.`

## Step 2: Media

Optional (without them, the listing image is shown). Upload these three, in
this order (1920x1080 .png, up to 10 allowed):

1. `gallery-1.png`: the plugin's highlights on a real bank, explained
2. `gallery-2.png`: the Recommended 14-tab layout
3. `gallery-3.png`: how it works, and what you can customise

Screenshots of the plugin window can be added later.

## Step 3: Dependencies

None. Leave empty.

## Step 4: Upload file

| Field | Value |
|---|---|
| File | `dist/bank-organiser-<version>.zip` |
| Platform | select **all**: Windows, Linux, Android, iOS and Source (required) |
| Version | the `version` from `plugin.json`, e.g. `1.0.0` (numbers and dots only) |
| Changelog | optional for the first version |
| Metadata blob | leave empty |

## After submitting

- You can still change the page or upload new files until moderation starts.
- When a moderator starts, they'll ask for a **code freeze**: no changes on
  mod.io until they finish (you can keep working in the repository).
- The report is Pass, Minor corrections, Major corrections or Fail.
- Later versions are uploaded as new files on the same plugin (not a new
  plugin); the approved version stays available while they're checked.
- Answer data-deletion requests sent to the contact email within one month.
