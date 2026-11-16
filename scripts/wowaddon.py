#!/usr/bin/env python3
#
# OO OO Guild Companion Release and Install tool
#
# Usage (from anywhere; a relative --dst is relative to the current directory):
#     python scripts/wowaddon.py --dst="<game>/_forever_/Interface/AddOns" install
#     python scripts/wowaddon.py --dst="../_Releases" zip
#
# Both commands first write Addon/OOOOguildcompanion.toc from Addon/toc_template.toc.
#

import argparse
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path
from typing import Iterator, Tuple

# Version bumping rules: Begin each new month with <year>.<month>.0 and increase by 1 with every new bump.
VERSION = "2026.11.0"  # year.month.build_num

ADDON_NAME = "OOOOguildcompanion"  # Directory, TOC and zip name
# ADDON_TITLE_CLASSIC = "OO OO Guild Companion Classic"  # Title field in TOC
ADDON_TITLE_FOREVER = "OO OO Guild Companion"  # Title field in TOC

# WoW: Forever is the only supported client. The other versions stay here as comments.
# UI_VERSION_CLASSIC = "11508"
# UI_VERSION_CLASSIC_TBC = "20506"  # The Burning Crusade
# UI_VERSION_CLASSIC_WOTLK = "30402"  # WotLK
# UI_VERSION_CLASSIC_CATA = "40402"  # Cataclysm
UI_VERSION_FOREVER = "16001"  # Forever; Mainline architecture, level-60 content

REPO_ROOT = Path(__file__).resolve().parent.parent
ADDON_ROOT = REPO_ROOT / "Addon"  # The addon root in the repository; packaged as ADDON_NAME
TOC_TEMPLATE = "toc_template.toc"

# Relative to ADDON_ROOT
COPY_DIRS = ["Ace3", "Emoji", "Icons", "Options"]
COPY_FILES = [
    "Core.lua",
    "embeds.xml",
]
# In ADDON_ROOT but not a part of the installed addon
NOT_PACKAGED = ["Art", ".luacheckrc", TOC_TEMPLATE]

# Client TOC suffixes: https://warcraft.wiki.gg/wiki/TOC_format
# Filenames use AddonName<SUFFIX>.toc. This addon ships one unsuffixed TOC, which Forever loads.
# SUFFIX_STANDARD = "_Standard"  # Midnight excluding other Modern modes
# SUFFIX_MISTS = "_Mists"  # Mists of Pandaria Classic
# SUFFIX_CATA = "_Cata"  # Cataclysm Classic
# SUFFIX_WRATH = "_Wrath"  # Wrath Classic and Titan Reforged
# SUFFIX_TBC = "_TBC"  # Burning Crusade Classic and Anniversary
# SUFFIX_CAMELOT = "_Camelot"  # WoW: Forever
# SUFFIX_VANILLA = "_Vanilla"  # World of Warcraft Classic (Era)
# SUFFIX_PLUNDERSTORM = "_Plunderstorm"
# SUFFIX_WOWLABS = "_WoWLabs"  # Unknown Modern mode
# SUFFIX_WOWHACK = "_WoWHack"  # Unknown Modern mode
# SUFFIX_MAINLINE = "_Mainline"  # Midnight, Modern modes, and Forever
# SUFFIX_CLASSIC = "_Classic"  # All Classic expansions, not specifically Era

# TOC file name suffix, interface version and title of every TOC to write
TOC_VARIANTS = (
    ("", UI_VERSION_FOREVER, ADDON_TITLE_FOREVER),
    # (SUFFIX_VANILLA, UI_VERSION_CLASSIC, ADDON_TITLE_CLASSIC),
    # (SUFFIX_TBC, UI_VERSION_CLASSIC_TBC, ADDON_TITLE_CLASSIC),
    # (SUFFIX_WRATH, UI_VERSION_CLASSIC_WOTLK, ADDON_TITLE_CLASSIC),
    # (SUFFIX_CATA, UI_VERSION_CLASSIC_CATA, ADDON_TITLE_CLASSIC),
)


class BuildTool:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.version = f"{VERSION}-{self.git_hash()}"
        self.copy_dirs = COPY_DIRS[:]
        self.copy_files = COPY_FILES[:]
        self.toc_files = [f"{ADDON_NAME}{suffix}.toc" for suffix, _, _ in TOC_VARIANTS]
        self.check_lists()

        for suffix, ui_version, title in TOC_VARIANTS:
            self.create_toc(dst=f"{ADDON_NAME}{suffix}.toc", ui_version=ui_version, title=title)

    def check_lists(self):
        """Stop when ADDON_ROOT has an entry which no list names: it would be missing in the game."""
        known = set(self.copy_dirs + self.copy_files + NOT_PACKAGED + self.toc_files)
        unknown = sorted(entry.name for entry in ADDON_ROOT.iterdir() if entry.name not in known)
        if unknown:
            sys.exit(f"Not in COPY_DIRS, COPY_FILES or NOT_PACKAGED of {Path(__file__).name}: "
                     + ", ".join(unknown))

    def package_files(self) -> Iterator[Tuple[Path, str]]:
        """Yield the source path and the name inside the addon folder of every packaged file."""
        for copy_dir in self.copy_dirs:
            for root, _dirs, files in os.walk(ADDON_ROOT / copy_dir):
                for file in sorted(files):
                    source = Path(root) / file
                    yield source, source.relative_to(ADDON_ROOT).as_posix()
        for copy_file in self.copy_files + self.toc_files:
            yield ADDON_ROOT / copy_file, copy_file

    def do_install(self):
        dst_path = Path(self.args.dst) / ADDON_NAME

        if dst_path.is_dir():
            print("Warning: Folder already exists, removing!")
            shutil.rmtree(dst_path)

        print(f"Destination: {dst_path}")
        count = 0
        for source, packaged_name in self.package_files():
            target = dst_path / packaged_name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(source, target)
            count += 1
        print(f"Installed {count} files, version {self.version}")

    def do_zip(self):
        os.makedirs(self.args.dst, exist_ok=True)
        zip_name = Path(self.args.dst) / f"{ADDON_NAME}-{VERSION}.zip"

        with zipfile.ZipFile(zip_name, "w", zipfile.ZIP_DEFLATED, allowZip64=True) as zip_file:
            count = 0
            for source, packaged_name in self.package_files():
                zip_file.write(source, f"{ADDON_NAME}/{packaged_name}")
                count += 1
        print(f"ZIP: {zip_name}, {count} files, version {self.version}")

    @staticmethod
    def git_hash() -> str:
        output = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO_ROOT)
        return output.decode("ascii").strip()[:8]

    def create_toc(self, dst: str, ui_version: str, title: str):
        template = (ADDON_ROOT / TOC_TEMPLATE).read_text(encoding="utf-8")
        template = template.replace("${UI_VERSION}", ui_version)
        template = template.replace("${VERSION}", self.version)
        template = template.replace("${ADDON_TITLE}", title)
        (ADDON_ROOT / dst).write_text(template, encoding="utf-8", newline="\n")


def main():
    parser = argparse.ArgumentParser(description="OO OO Guild Companion Release and Install tool")
    parser.add_argument(
        "--dst",
        type=str,
        required=True,
        action="store",
        help="The destination directory where the game Addons will be copied, "
        "or where ZIP will be stored. TOC name will serve as directory "
        "name.",
    )

    # parser.add_argument(
    #     "--version",
    #     choices=["classic", "tbc", "wotlk", "cata", "forever"],
    #     help="Select the game version to package.",
    # )

    parser.add_argument(
        "command",
        choices=["help", "zip", "install"],
        help="The action to take. ZIP will create an archive. Install will copy",
    )

    args = parser.parse_args(sys.argv[1:])

    if args.command == "install":
        BuildTool(args).do_install()
    elif args.command == "zip":
        BuildTool(args).do_zip()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
