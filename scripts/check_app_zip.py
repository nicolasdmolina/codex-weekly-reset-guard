"""Check the contents and Unix file types before macOS unpacks the release."""

from pathlib import PurePosixPath
import stat
import sys
from zipfile import BadZipFile, ZipFile


CONTENTS = PurePosixPath("Second Wind.app/Contents")
EXECUTABLE = str(CONTENTS / "MacOS/SecondWind")
FILES = {
    EXECUTABLE,
    str(CONTENTS / "Info.plist"),
    str(CONTENTS / "Resources/AppIcon.icns"),
    str(CONTENTS / "Resources/LICENSE"),
    str(CONTENTS / "_CodeSignature/CodeResources"),
}
DIRECTORIES = {
    f"{parent}/" for name in FILES for parent in PurePosixPath(name).parents
    if parent != PurePosixPath(".")
}


def check(archive):
    seen = set()
    for entry in archive.infolist():
        name = entry.filename
        if name != entry.orig_filename or name in seen:
            raise ValueError("ambiguous or duplicate ZIP entry")
        seen.add(name)
        mode = entry.external_attr >> 16
        if name in DIRECTORIES:
            valid_type = stat.S_ISDIR(mode)
        elif name in FILES:
            valid_type = stat.S_ISREG(mode)
        else:
            raise ValueError("unexpected path in the app ZIP")
        if not valid_type or mode & 0o7000 or entry.flag_bits & 1:
            raise ValueError("unsupported file type, permissions or encryption in the app ZIP")
        if name == EXECUTABLE and not mode & stat.S_IXUSR:
            raise ValueError("the app's executable lost its execute permission")
    if FILES - seen:
        raise ValueError("missing app files: " + ", ".join(sorted(FILES - seen)))


if __name__ == "__main__":
    try:
        with ZipFile(sys.argv[1]) as source:
            check(source)
    except (BadZipFile, ValueError, OSError) as error:
        sys.exit(f"Invalid Second Wind app ZIP: {error}")
