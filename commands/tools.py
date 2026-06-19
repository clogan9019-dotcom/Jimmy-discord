"""Lightweight utility commands and AI-callable tools."""

from __future__ import annotations

import asyncio
import html
import logging
import os
import re
import urllib.parse
import urllib.request
from pathlib import Path
from typing import TYPE_CHECKING

import discord
from discord import app_commands

if TYPE_CHECKING:
    from bot import DiscordBitNetBot

log = logging.getLogger(__name__)

_SEARCH_LIMIT = 5
_HTTP_TIMEOUT = 10
_SHELL_TIMEOUT = 15
_OUTPUT_LIMIT = 1800


def _strip_tags(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value)
    value = html.unescape(value)
    return re.sub(r"\s+", " ", value).strip()


def _clean_duckduckgo_url(url: str) -> str:
    url = html.unescape(url)
    if url.startswith("//"):
        url = "https:" + url
    if url.startswith("/"):
        url = "https://duckduckgo.com" + url

    parsed = urllib.parse.urlparse(url)
    qs = urllib.parse.parse_qs(parsed.query)
    if "uddg" in qs and qs["uddg"]:
        return qs["uddg"][0]
    return url


def _search_duckduckgo(query: str, limit: int = _SEARCH_LIMIT) -> list[dict[str, str]]:
    """Very small DuckDuckGo HTML scraper using only the Python stdlib."""
    params = urllib.parse.urlencode({"q": query})
    url = f"https://html.duckduckgo.com/html/?{params}"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": (
                "Mozilla/5.0 (X11; Linux aarch64) AppleWebKit/537.36 "
                "KHTML, like Gecko Chrome/120 Safari/537.36"
            )
        },
    )
    with urllib.request.urlopen(req, timeout=_HTTP_TIMEOUT) as resp:
        page = resp.read().decode("utf-8", errors="replace")

    matches = list(
        re.finditer(
            r'<a[^>]+class="result__a"[^>]+href="([^"]+)"[^>]*>(.*?)</a>',
            page,
            flags=re.IGNORECASE | re.DOTALL,
        )
    )

    results: list[dict[str, str]] = []
    for idx, match in enumerate(matches[:limit]):
        title = _strip_tags(match.group(2))
        result_url = _clean_duckduckgo_url(match.group(1))

        # Snippet usually appears between this result link and the next result link.
        next_start = matches[idx + 1].start() if idx + 1 < len(matches) else len(page)
        block = page[match.end():next_start]
        snippet_match = re.search(
            r'<a[^>]+class="result__snippet"[^>]*>(.*?)</a>',
            block,
            flags=re.IGNORECASE | re.DOTALL,
        ) or re.search(
            r'<div[^>]+class="result__snippet"[^>]*>(.*?)</div>',
            block,
            flags=re.IGNORECASE | re.DOTALL,
        )
        snippet = _strip_tags(snippet_match.group(1)) if snippet_match else ""

        if title and result_url:
            results.append({"title": title, "url": result_url, "snippet": snippet})

    return results


def _format_search_results(query: str, results: list[dict[str, str]]) -> str:
    if not results:
        return f"No search results found for: `{query}`"

    lines = [f"🔎 **Search results for:** `{query}`"]
    for i, result in enumerate(results, start=1):
        title = result["title"][:180]
        url = result["url"]
        snippet = result.get("snippet", "")[:240]
        lines.append(f"\n**{i}. [{title}](<{url}> )**".replace(" >", ">"))
        if snippet:
            lines.append(f"> {snippet}")
    text = "\n".join(lines)
    return text[:3900]




async def _run_shell(command: str) -> tuple[int | None, str]:
    proc = await asyncio.create_subprocess_shell(
        command,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        cwd=str(Path.cwd()),
        executable="/bin/bash" if os.name != "nt" else None,
    )
    try:
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=_SHELL_TIMEOUT)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return None, f"Command timed out after {_SHELL_TIMEOUT}s."

    out = stdout.decode("utf-8", errors="replace")
    err = stderr.decode("utf-8", errors="replace")
    combined = ""
    if out:
        combined += out
    if err:
        combined += ("\n--- stderr ---\n" if combined else "--- stderr ---\n") + err
    if not combined.strip():
        combined = "(no output)"
    return proc.returncode, combined.strip()


async def search_tool(query: str) -> str:
    """AI-callable lightweight web search tool."""
    results = await asyncio.to_thread(_search_duckduckgo, query, _SEARCH_LIMIT)
    return _format_search_results(query, results)


async def shell_tool(command: str) -> str:
    """AI-callable shell tool. Caller must enforce owner-only access."""
    returncode, output = await _run_shell(command)
    header = "timed out" if returncode is None else f"exit {returncode}"
    if len(output) > _OUTPUT_LIMIT:
        output = output[-_OUTPUT_LIMIT:]
        output = "... output truncated ...\n" + output
    return f"{header}\n{output}"

def setup_tool_commands(bot: "DiscordBitNetBot") -> None:
    """Register lightweight utility slash commands."""

    @bot.tree.command(name="search", description="Lightweight web search.")
    @app_commands.describe(query="What to search for.")
    async def search(interaction: discord.Interaction, query: str) -> None:
        await interaction.response.defer(thinking=True)
        try:
            await interaction.followup.send(await search_tool(query))
            log.info("Search requested by user_id=%s query=%r", interaction.user.id, query)
        except Exception as exc:
            log.exception("Search failed for query=%r", query)
            await interaction.followup.send(f"❌ Search failed: `{type(exc).__name__}: {exc}`")

    @bot.tree.command(name="shell", description="Owner-only shell command on the Pi.")
    @app_commands.describe(command="Shell command to run on the Pi.")
    async def shell(interaction: discord.Interaction, command: str) -> None:
        if not await bot.is_owner(interaction.user):
            await interaction.response.send_message("❌ Owner only.", ephemeral=True)
            return
        await interaction.response.defer(thinking=True, ephemeral=True)
        output = await shell_tool(command)
        await interaction.followup.send(f"```\n{output}\n```", ephemeral=True)
        log.warning("Shell command run by owner user_id=%s: %s", interaction.user.id, command)
