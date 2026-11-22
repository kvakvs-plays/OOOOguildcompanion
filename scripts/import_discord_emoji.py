#!/usr/bin/env python3
"""Import the custom emoji of Discord guilds into Addon/Icons/Emoji/<guild id>/, and pack all
emoji into the texture atlas that the addon loads.

Usage (from anywhere):
    python scripts/import_discord_emoji.py                 # the guilds in DEFAULT_GUILD_IDS
    python scripts/import_discord_emoji.py 123 456         # these guilds instead
    python scripts/import_discord_emoji.py --index-only    # download nothing, only build the atlas
    python scripts/import_discord_emoji.py --also-standard-emoji   # also replace Icons/Emoji/discord

The PNG files, one per emoji, are the source and are not a part of the installed addon. Every
run builds two outputs from them:
- The atlas Addon/Icons/Emoji/Atlas<page>.png: all emoji on disk in a grid with one empty pixel
  between them, the guild emoji first. A page is a square of at most --atlas-size pixels; a new
  page starts when one is full.
- Addon/Src/Emoji/EmojiSprites.lua with `ns.emojiSprites`, the page and the coordinates of every
  emoji by its id, and `ns.emojiTriggerStrings`, the lower case strings that show an emoji in
  chat -> emoji id. A guild emoji is triggered by its name. A standard emoji is triggered by
  ":<name>" and ":<name>:", for every name that Discord has for it.

The standard emoji of Discord (the Unicode ones, such as :joy:) go into Addon/Icons/Emoji/discord/,
one PNG per emoji under its first Discord name, with all the names in names.json. They are imported
only with --also-standard-emoji; once the folder is there, every run packs them. They need no bot
token: the names come from the npm package discord-emoji and the images from Twemoji, the set that
Discord draws, both through jsDelivr.

Needs:
- A Discord bot token in the DISCORD_BOT_TOKEN environment variable, or as a
  DISCORD_BOT_TOKEN=... line in the .env file in the repository root. The bot must be a
  member of every guild in the list; it needs no permissions and no intents.
- ImageMagick (`magick`) on PATH, to pad every emoji to a square texture and to build the atlas.

Every run replaces the PNG files of the imported guilds, so an emoji which was deleted on
Discord disappears here too. Animated emoji are saved as their first frame.
"""

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_GUILD_IDS = [
    1365460236676235314,
]

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "Addon" / "Icons" / "Emoji"
SPRITES_FILE = REPO_ROOT / "Addon" / "Src" / "Emoji" / "EmojiSprites.lua"
API = "https://discord.com/api/v10"
CDN = "https://cdn.discordapp.com"
# Discord rejects requests without a User-Agent of this form
USER_AGENT = "DiscordBot (https://github.com/discord/discord-api-docs, 1.0)"
# Side of the square texture in pixels; the Discord CDN serves powers of two only
DEFAULT_SIZE = 64

# Folder of the standard emoji under OUTPUT_ROOT
STANDARD_DIR_NAME = "discord"
# Discord's names of the standard emoji: JavaScript objects of "name": "emoji" lines, one per category
STANDARD_NAMES_URL = "https://cdn.jsdelivr.net/npm/discord-emoji@2.5.3/esm/mod.js"
# Twemoji images, 72x72, named by the code points of the emoji
STANDARD_IMAGE_URL = "https://cdn.jsdelivr.net/gh/jdecked/twemoji@17.0.3/assets/72x72/{code}.png"
STANDARD_DOWNLOAD_THREADS = 16
# In the folder of the standard emoji: Discord name -> file name without extension
STANDARD_NAMES_FILE = "names.json"

# Atlas pages are OUTPUT_ROOT/Atlas<page>.png, from page 1
ATLAS_PREFIX = "Atlas"
# Side of an atlas page in pixels. That the client loads a texture larger than this is not checked.
DEFAULT_ATLAS_SIZE = 2048
# Empty pixels between two emoji in the atlas: the client blends neighbouring pixels when it draws
# an emoji smaller or larger, and without the gap the edge of the next emoji shows as a thin line
ATLAS_GAP = 1


def read_token() -> str:
    token = os.environ.get("DISCORD_BOT_TOKEN", "").strip()
    env_file = REPO_ROOT / ".env"
    if not token and env_file.is_file():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip() == "DISCORD_BOT_TOKEN":
                token = value.strip().strip("\"'")
    if not token:
        sys.exit("No bot token: set DISCORD_BOT_TOKEN in the environment or in the .env file "
                 f"at {env_file}")
    return token


def fetch(url: str, token: str | None = None) -> bytes:
    """GET a URL, waiting and retrying when Discord answers with a rate limit."""
    headers = {"User-Agent": USER_AGENT}
    if token:
        headers["Authorization"] = f"Bot {token}"
    for _ in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=30) as reply:
                return reply.read()
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            wait = float(error.headers.get("Retry-After", "1"))
            print(f"  rate limited, waiting {wait:.1f} s")
            time.sleep(wait + 0.1)
    raise RuntimeError(f"Still rate limited after 5 attempts: {url}")


def explain(error: urllib.error.HTTPError, guild_id: int) -> str:
    if error.code == 401:
        return "the bot token was rejected (401)"
    if error.code in (403, 404):
        return f"the bot is not a member of guild {guild_id}, or the id is wrong ({error.code})"
    return f"HTTP {error.code} {error.reason}"


def file_names(emojis: list[dict]) -> dict[str, str]:
    """Emoji id -> file name without extension. Discord allows two emoji with one name, and
    names which differ only by case collide on Windows, so later duplicates get the id."""
    names: dict[str, str] = {}
    used: set[str] = set()
    for emoji in sorted(emojis, key=lambda e: int(e["id"])):
        name = re.sub(r"[^A-Za-z0-9_]", "_", emoji["name"] or "") or "emoji"
        if name.lower() in used:
            name = f"{name}_{emoji['id']}"
        used.add(name.lower())
        names[emoji["id"]] = name
    return names


def import_guild(guild_id: int, token: str, size: int) -> int | None:
    """Returns the number of imported emoji, or None when the guild could not be read."""
    try:
        emojis = json.loads(fetch(f"{API}/guilds/{guild_id}/emojis", token))
    except urllib.error.HTTPError as error:
        print(f"Guild {guild_id}: FAILED, {explain(error, guild_id)}")
        return None

    target_dir = OUTPUT_ROOT / str(guild_id)
    target_dir.mkdir(parents=True, exist_ok=True)
    for old in target_dir.glob("*.png"):
        old.unlink()

    print(f"Guild {guild_id}: {len(emojis)} emoji -> {target_dir}")
    names = file_names(emojis)
    for emoji in emojis:
        target = target_dir / f"{names[emoji['id']]}.png"
        target.write_bytes(fetch(f"{CDN}/emojis/{emoji['id']}.png?size={size}"))
        # The CDN keeps the aspect ratio, so a wide emoji arrives as e.g. 64x40. Pad it to
        # a square with transparent borders; the game stretches a texture to its frame.
        subprocess.run(
            ["magick", str(target), "-background", "none", "-gravity", "center",
             "-resize", f"{size}x{size}", "-extent", f"{size}x{size}", "-strip", f"PNG32:{target}"],
            check=True)
    return len(emojis)


def standard_emoji() -> tuple[dict[str, str], dict[str, str]]:
    """Returns the standard emoji of Discord as two tables: file name without extension ->
    Twemoji file code, and Discord name -> file name. Discord has several names for most emoji
    (`grinning`, `grinning_face`); the file gets the first, and the second table has them all."""
    source = fetch(STANDARD_NAMES_URL).decode("utf-8")
    files: dict[str, str] = {}
    by_code: dict[str, str] = {}
    names: dict[str, str] = {}
    for quoted_name, quoted_emoji in re.findall(r'^\s*("(?:[^"\\]|\\.)*"):\s*("(?:[^"\\]|\\.)*"),?\s*$',
                                                source, re.MULTILINE):
        name, emoji = json.loads(quoted_name).lower(), json.loads(quoted_emoji)
        # Twemoji drops the variation selector from its file names, except in a joined sequence
        if "\u200d" not in emoji:
            emoji = emoji.replace("\ufe0f", "")
        code = "-".join(f"{ord(char):x}" for char in emoji)
        if not code:
            continue
        if code not in by_code:
            file_name = re.sub(r"[^a-z0-9_]", "_", name) or "emoji"
            if file_name in files:
                file_name = f"{file_name}_{code.replace('-', '_')}"
            files[file_name] = code
            by_code[code] = file_name
        # The addon finds a name as one word of letters, digits, and underscores, so `+1` cannot
        # be found; such an emoji has another name (`thumbsup`)
        if re.fullmatch(r"\w+", name):
            names.setdefault(name, by_code[code])
    if not files:
        raise RuntimeError(f"No emoji names found in {STANDARD_NAMES_URL}")
    return files, names


def import_standard(size: int) -> int | None:
    """Replaces the folder of the standard emoji. Returns the number of imported emoji, or None
    when the import failed; the folder is then as it was before."""
    target_dir = OUTPUT_ROOT / STANDARD_DIR_NAME
    # The folder appears only when it is complete, so a failed import leaves the old one
    work_dir = OUTPUT_ROOT / (STANDARD_DIR_NAME + ".tmp")
    if work_dir.exists():
        shutil.rmtree(work_dir)

    def download(item: tuple[str, str]) -> bool:
        name, code = item
        try:
            (work_dir / f"{name}.png").write_bytes(fetch(STANDARD_IMAGE_URL.format(code=code)))
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            return False  # an emoji that this Twemoji version does not draw
        return True

    try:
        files, names = standard_emoji()
        work_dir.mkdir(parents=True)
        print(f"Standard emoji: downloading {len(files)} images")
        with concurrent.futures.ThreadPoolExecutor(STANDARD_DOWNLOAD_THREADS) as pool:
            found = list(pool.map(download, files.items()))
        missing = [name for name, ok in zip(files, found) if not ok]
        if missing:
            print(f"  no image for {len(missing)} emoji: {', '.join(missing[:20])}"
                  + (" ..." if len(missing) > 20 else ""))
        # One call for the whole folder: a process per file takes minutes on Windows
        subprocess.run(
            ["magick", "mogrify", "-background", "none", "-gravity", "center",
             "-resize", f"{size}x{size}", "-extent", f"{size}x{size}", "-strip",
             "-define", "png:color-type=6", "-define", "png:bit-depth=8", str(work_dir / "*.png")],
            check=True)
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Standard emoji: FAILED, {error}")
        shutil.rmtree(work_dir, ignore_errors=True)
        return None

    if target_dir.exists():
        shutil.rmtree(target_dir)
    names = {name: file for name, file in names.items() if file not in missing}
    (work_dir / STANDARD_NAMES_FILE).write_text(
        json.dumps(names, ensure_ascii=False, indent=0) + "\n", encoding="utf-8", newline="\n")
    work_dir.rename(target_dir)
    count = len(files) - len(missing)
    print(f"Standard emoji: {count} emoji -> {target_dir}")
    return count


def collect_sprites() -> tuple[list[dict], dict[str, int]]:
    """Reads the PNG files on disk. Returns the emoji in atlas order (the id of an emoji is its
    position, from 1) and the trigger strings: lower case string -> id."""
    sprites: list[dict] = []
    triggers: dict[str, int] = {}

    # The guild emoji come first: they are the ones in daily use, so their page is loaded anyway
    guild_names: set[str] = set()
    guild_dirs = [d for d in OUTPUT_ROOT.iterdir() if d.is_dir() and d.name.isdigit()]
    for guild_dir in sorted(guild_dirs, key=lambda d: int(d.name)):
        for png in sorted(guild_dir.glob("*.png"), key=lambda f: (f.stem.lower(), f.stem)):
            # The name is the key of the settings, so the first guild wins when two have one name
            if png.stem in guild_names:
                continue
            guild_names.add(png.stem)
            sprites.append({"name": png.stem, "file": png, "standard": False})
            triggers.setdefault(png.stem.lower(), len(sprites))

    standard_dir = OUTPUT_ROOT / STANDARD_DIR_NAME
    names_file = standard_dir / STANDARD_NAMES_FILE
    if names_file.is_file():
        names: dict[str, str] = json.loads(names_file.read_text(encoding="utf-8"))
        ids: dict[str, int] = {}
        # The names are in the order of Discord, which starts with the faces: the emoji in common
        # use land on the first pages
        for file_name in dict.fromkeys(names.values()):
            png = standard_dir / f"{file_name}.png"
            if png.is_file():
                sprites.append({"name": file_name, "file": png, "standard": True})
                ids[file_name] = len(sprites)
        for name in sorted(names):
            emoji_id = ids.get(names[name])
            if emoji_id:
                # A name of one character needs both colons: ":o" and ":x" are smileys
                if len(name) > 1:
                    triggers.setdefault(f":{name}", emoji_id)
                triggers.setdefault(f":{name}:", emoji_id)
    return sprites, triggers


def build_atlas(cell: int, atlas_size: int) -> None:
    """Packs all emoji on disk into the atlas pages and writes the Lua file with the sprites and
    the trigger strings. All emoji are squares of one size, so a grid is the densest packing."""
    sprites, triggers = collect_sprites()
    pitch = cell + ATLAS_GAP

    def capacity(size: int) -> int:
        # The last column and row need no gap after them
        return ((size + ATLAS_GAP) // pitch) ** 2

    # Pages are powers of two. When everything fits on one smaller page, that page is used
    while atlas_size > pitch and capacity(atlas_size // 2) >= len(sprites):
        atlas_size //= 2
    columns = (atlas_size + ATLAS_GAP) // pitch
    per_page = columns * columns
    pages = (len(sprites) + per_page - 1) // per_page

    for old in OUTPUT_ROOT.glob(f"{ATLAS_PREFIX}*.png"):
        old.unlink()
    with tempfile.TemporaryDirectory() as temp:
        for page in range(pages):
            on_page = sprites[page * per_page:(page + 1) * per_page]
            for index, sprite in enumerate(on_page):
                sprite["page"] = page + 1
                sprite["x"] = (index % columns) * pitch
                sprite["y"] = (index // columns) * pitch
            # The file names go through a list file: a thousand of them do not fit a command line
            list_file = Path(temp) / "files.txt"
            list_file.write_text("".join(f'"{sprite["file"].as_posix()}"\n' for sprite in on_page),
                                 encoding="utf-8")
            grid = Path(temp) / "grid.png"
            subprocess.run(
                # A tile is the emoji in its top left corner with the gap to the right and below;
                # ">" keeps montage from enlarging the emoji to the tile
                ["magick", "montage", f"@{list_file}", "-tile", f"{columns}x", "-gravity", "NorthWest",
                 "-geometry", f"{pitch}x{pitch}>+0+0", "-background", "none", f"PNG32:{grid}"],
                check=True)
            # A page is always the full square, also the last one, which is not full
            subprocess.run(
                ["magick", str(grid), "-background", "none", "-gravity", "NorthWest",
                 "-extent", f"{atlas_size}x{atlas_size}", "-strip",
                 f"PNG32:{OUTPUT_ROOT / f'{ATLAS_PREFIX}{page + 1}.png'}"],
                check=True)
    print(f"Atlas: {len(sprites)} emoji on {pages} page(s) of {atlas_size}x{atlas_size} -> {OUTPUT_ROOT}")

    lines = [
        "-- Generated by scripts/import_discord_emoji.py from the files in Icons/Emoji. Do not edit.",
        "-- luacheck: no max line length",
        "local addonName, ns = ...",
        "",
        "---@class OOOOEmojiAtlas The texture atlas with all emoji; a page is Icons\\Emoji\\Atlas<page>.png",
        "---@field size integer Side of a page in pixels",
        "---@field cell integer Side of an emoji in pixels",
        "---@field pages integer Number of pages",
        "",
        "---@type OOOOEmojiAtlas",
        f"ns.emojiAtlas = {{ size = {atlas_size}, cell = {cell}, pages = {max(pages, 1)} }}",
        "",
        "---@class OOOOEmojiSprite An emoji in the atlas",
        "---@field name string Guild emoji: its name. Standard emoji: its first Discord name",
        "---@field page integer Atlas page, from 1",
        "---@field x integer Left edge on the page in pixels",
        "---@field y integer Top edge on the page in pixels",
        "---@field standard boolean|nil true for a standard emoji of Discord, nil for a guild emoji",
        "",
        "---Emoji id -> place in the atlas. The ids change with every import; nothing may store one.",
        "---@type OOOOEmojiSprite[]",
        "ns.emojiSprites = {",
    ]
    for sprite in sprites:
        standard = ", standard = true" if sprite["standard"] else ""
        lines.append(f'  {{ name = "{sprite["name"]}", page = {sprite["page"]}, x = {sprite["x"]}, '
                     f'y = {sprite["y"]}{standard} }},')
    lines += [
        "}",
        "",
        "---String in lower case which shows an emoji in chat -> emoji id. A guild emoji has its name here;",
        "---a standard emoji has `:name` and `:name:` for every name that Discord gives it.",
        "---@type table<string, integer>",
        "ns.emojiTriggerStrings = {",
    ]
    lines += [f'  ["{trigger}"] = {triggers[trigger]},' for trigger in sorted(triggers)]
    lines.append("}")
    SPRITES_FILE.parent.mkdir(parents=True, exist_ok=True)
    SPRITES_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"Sprites: {len(sprites)} emoji, {len(triggers)} trigger strings -> {SPRITES_FILE}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Import Discord guild emoji as addon textures.")
    parser.add_argument("guild_ids", nargs="*", type=int, help="guild ids; default: the list in the script")
    parser.add_argument("--size", type=int, default=DEFAULT_SIZE, choices=[16, 32, 64, 128, 256],
                        help=f"texture side in pixels (default {DEFAULT_SIZE})")
    parser.add_argument("--index-only", action="store_true",
                        help="download nothing; only build the atlas and its Lua file from the files on disk")
    parser.add_argument("--atlas-size", type=int, default=DEFAULT_ATLAS_SIZE, choices=[1024, 2048, 4096],
                        help=f"largest side of an atlas page in pixels (default {DEFAULT_ATLAS_SIZE})")
    parser.add_argument("--also-standard-emoji", action="store_true",
                        help=f"import the standard emoji into Icons/Emoji/{STANDARD_DIR_NAME}, replacing the folder; "
                             "without it they are never downloaded")
    args = parser.parse_args()

    if not shutil.which("magick"):
        sys.exit("ImageMagick (`magick`) was not found on PATH")
    if args.index_only:
        build_atlas(args.size, args.atlas_size)
        return

    token = read_token()

    guild_ids = args.guild_ids or DEFAULT_GUILD_IDS
    counts = [import_guild(guild_id, token, args.size) for guild_id in guild_ids]
    failed = counts.count(None)
    standard_failed = False
    if args.also_standard_emoji:
        standard_failed = import_standard(args.size) is None
    build_atlas(args.size, args.atlas_size)
    print(f"Done: {sum(c or 0 for c in counts)} emoji from {len(counts) - failed} guild(s), {failed} failed")
    if failed or standard_failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
