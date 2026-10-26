# Third-party software in Toolbox

Toolbox ships these programs inside the app (Contents/Resources) and runs them as separate processes.

## yt-dlp
Public domain (The Unlicense). https://github.com/yt-dlp/yt-dlp
The standalone macOS build bundles Python (PSF License) and other libraries; see the yt-dlp
repository for their licenses.

## FFmpeg (ffmpeg, ffprobe)
Licensed under the GNU Lesser General Public License, version 2.1 or later. https://ffmpeg.org
Toolbox's copy is built from the unmodified FFmpeg source with `--disable-gpl --disable-nonfree`
and no external codec libraries, using `scripts/fetch-tools.sh` in the Toolbox repository.
The exact source tarball is https://ffmpeg.org/releases/ (version named in that script).
You may rebuild and replace these programs: run `scripts/fetch-tools.sh` and copy the results over
`Toolbox.app/Contents/Resources/ffmpeg` and `ffprobe`.

Toolbox is not affiliated with the FFmpeg or yt-dlp projects.
