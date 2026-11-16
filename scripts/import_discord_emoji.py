#!/usr/bin/env python3
"""Import the custom emoji of Discord guilds into Addon/Icons/Emoji/<guild id>/.

Usage (from anywhere):
    python scripts/import_discord_emoji.py                 # the guilds in DEFAULT_GUILD_IDS
    python scripts/import_discord_emoji.py 123 456         # these guilds instead

Needs:
- A Discord bot token in the DISCORD_BOT_TOKEN environment variable, or as a
  DISCORD_BOT_TOKEN=... line in the .env file in the repository root. The bot must be a
  member of every guild in the list; it needs no permissions and no intents.
- ImageMagick (`magick`) on PATH, to pad every emoji to a square texture.

Every run replaces the PNG files of the imported guilds, so an emoji which was deleted on
Discord disappears here too. Animated emoji are saved as their first frame.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_GUILD_IDS = [
    1365460236676235314,
]

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_ROOT = REPO_ROOT / "Addon" / "Icons" / "Emoji"
API = "https://discord.com/api/v10"
CDN = "https://cdn.discordapp.com"
# Discord rejects requests without a User-Agent of this form
USER_AGENT = "DiscordBot (https://github.com/discord/discord-api-docs, 1.0)"
# Side of the square texture in pixels; the Discord CDN serves powers of two only
DEFAULT_SIZE = 64


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


def main() -> None:
    parser = argparse.ArgumentParser(description="Import Discord guild emoji as addon textures.")
    parser.add_argument("guild_ids", nargs="*", type=int, help="guild ids; default: the list in the script")
    parser.add_argument("--size", type=int, default=DEFAULT_SIZE, choices=[16, 32, 64, 128, 256],
                        help=f"texture side in pixels (default {DEFAULT_SIZE})")
    args = parser.parse_args()

    if not shutil.which("magick"):
        sys.exit("ImageMagick (`magick`) was not found on PATH")
    token = read_token()

    guild_ids = args.guild_ids or DEFAULT_GUILD_IDS
    counts = [import_guild(guild_id, token, args.size) for guild_id in guild_ids]
    failed = counts.count(None)
    print(f"Done: {sum(c or 0 for c in counts)} emoji from {len(counts) - failed} guild(s), {failed} failed")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
