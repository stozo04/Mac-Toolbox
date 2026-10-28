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

## libwebp (WebP encoder)
Compiled into the Toolbox app itself (not a separate program) so it can save WebP images. Version 1.6.0,
unmodified source in `Sources/CWebP/`. https://chromium.googlesource.com/webm/libwebp
BSD 3-Clause license:

    Copyright (c) 2010, Google Inc. All rights reserved.

    Redistribution and use in source and binary forms, with or without
    modification, are permitted provided that the following conditions are
    met:

      * Redistributions of source code must retain the above copyright
        notice, this list of conditions and the following disclaimer.

      * Redistributions in binary form must reproduce the above copyright
        notice, this list of conditions and the following disclaimer in
        the documentation and/or other materials provided with the
        distribution.

      * Neither the name of Google nor the names of its contributors may
        be used to endorse or promote products derived from this software
        without specific prior written permission.

    THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
    "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
    LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
    A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
    HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
    SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
    LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
    DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
    THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
    (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
    OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

Toolbox is not affiliated with the FFmpeg, yt-dlp or WebP projects.
