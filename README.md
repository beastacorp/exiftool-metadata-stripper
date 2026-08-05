# ExifTool Metadata Stripper

A stripped-down, removal-only companion to ExifTool. It does exactly one
thing: delete all metadata from the files or folders you give it. There is
no tag editor, no "set a value", no swapping, no renaming, no format
conversion. If you need to *edit* metadata, use the full `exiftool` -- this tool is deliberately not that.

## What's here

| File | Purpose |
|---|---|
| `exif_metadata_stripper.pl` | The GUI application (Perl/Tk). |
| `lib/ExifStripper/Core.pm` | All the actual logic: finding files, deciding what's safe to touch, and doing the removal. No GUI code in here, so it can be reused or tested standalone. |
| `build.bat` | Run this to build the `.exe`. |
| `pp_build_exe.args` | The `pp` arguments `build.bat` uses. You shouldn't need to run this file directly. |
| `README.md` | This file. |

It uses the full `Image::ExifTool` library from `../lib` (the same one the
main `exiftool` app uses) so it can correctly recognize and clean every file
format ExifTool supports -- that library is not something a "simplified"
build can shrink, since removal still requires understanding each format's
metadata layout.

## Features

- **Removal only.** The only operation is "delete all metadata from this
  file." Nothing else is exposed in the UI or the code.
- **Drag and drop.** Same mechanism the stock `exiftool.exe`/
  `windows_exiftool.exe` already uses: drop files or folders onto the built
  `.exe`'s icon (or a shortcut to it) and Windows passes them in as
  arguments. No custom drag-and-drop handling was written -- it's the same
  interaction users already know from ExifTool's Windows build. You can also
  add more files/folders after the window is open, via **Add Files...** and
  **Add Folder...**.
- **Folders are scanned recursively** for files automatically.
- **"Are you sure?" confirmation** before anything on disk is touched,
  showing how many files are about to be affected.
- **Optional backups**, chosen right in the confirmation prompt via a
  checkbox (checked by default). When checked, each file is copied to
  `<name>.<ext>_original` next to it before stripping (the same convention
  ExifTool's own command-line default backup uses), so a mistake can be
  undone by hand. Unchecking it strips files in place with no way to
  recover the original metadata through this tool -- the dialog says so
  in red text.
- **RAW/proprietary formats are skipped automatically** (CR2, CR3, CRW, NEF,
  NRW, ARW, SRF, SR2, ORF, RAF, RW2, PEF, DNG, RAW, ERF, MRW, X3F, 3FR, IIQ,
  MOS, SRW, GPR) -- ExifTool's own documentation warns that blanket-deleting
  all metadata from these can make the file unusable, since manufacturers
  sometimes store data the decoder needs in the makernotes. These files are
  listed in the activity log as skipped rather than silently ignored.
- **Activity log and result summary** so it's clear what happened to every
  file, not just a silent pass/fail.

## What was intentionally removed (vs. full ExifTool)

- Setting, editing, or copying tag values (`-TAG=value`, `-TagsFromFile`, etc.)
- Renaming files based on metadata
- Any format conversion or write of new metadata of any kind
- Command-line option parsing (`-@ argfile`, `-stay_open`, CSV/JSON import,
  geotagging, etc.) -- none of that machinery is reachable from this tool
- Compression/archive helper modules the CLI needs for its broader feature
  set (`Archive::Zip`, `Digest::MD5`/`Digest::SHA`, the `IO::Compress::*` /
  `IO::Uncompress::*` family, `Time::Piece`) are left out of the packaged
  `.exe` -- see `pp_build_exe.args`. `Compress::Zlib` is kept because some
  common formats (e.g. compressed PNG text chunks) need it even for removal.

## Running it without building an .exe

```
cd strip_tool
perl exif_metadata_stripper.pl [file_or_folder ...]
```

Requires Perl/Tk (`cpan install Tk`, or `libtk-perl` on Debian/Ubuntu, or it
ships with Strawberry Perl on Windows).

## Building the stand-alone Windows .exe

```
cpan install PAR::Packer Tk      # once, on the machine you build on
```

then run **`build.bat`** in this directory (double-click it in Explorer, or
`.\build.bat` from PowerShell/cmd).

Partway through, the app itself will pop up on screen -- that's expected.
Perl/Tk loads most of its widget classes on demand rather than via a plain
`use`, so `pp` can't see all of them by just reading the source; the
officially-documented fix (`pp`'s `-x` flag) is to actually run the app once
during packaging and record what it loads. `build.bat` prints exactly what
to click through before that window appears, and once you close it, the
build finishes on its own with no further input.

If a *future* code change adds a new kind of Tk widget and the built `.exe`
ever complains about a missing `Tk::Something` module, add `-M
Tk::Something` to `pp_build_exe.args` and rebuild -- but that shouldn't come
up for the app as it stands today.

## Testing performed

`lib/ExifStripper/Core.pm` has no GUI dependency, so its logic was exercised
directly against real sample images from `../t/images/`:

- Recursive folder collection found files nested in subfolders correctly.
- Stripping a JPEG with embedded EXIF/IPTC/XMP/MakerNotes went from 100+
  metadata tags down to only the handful of filesystem-derived tags
  (file size, dimensions, MIME type, etc.) that aren't embedded metadata at
  all -- confirming the removal is thorough.
- A `.CR2` RAW sample was correctly skipped rather than stripped.
- A `*_original` backup was created next to each stripped file and left
  untouched by the operation.

The Perl/Tk GUI script (`exif_metadata_stripper.pl`) was syntax-checked and
then exercised end-to-end against a stub Tk implementation (Perl/Tk isn't
installable in the sandbox this was built in) to confirm the button/dialog
wiring calls into `ExifStripper::Core` correctly and that startup
correctly loads paths passed on `@ARGV` (the drag-and-drop-onto-.exe case).
That test caught and fixed one real bug (`-padx => (0, 6)` was flattening
into the surrounding argument list instead of being passed as the `[0, 6]`
array-ref Tk expects). It cannot substitute for actually clicking through
the built `.exe` on Windows, which you should still do before relying on it.
