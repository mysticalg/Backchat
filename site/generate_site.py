from __future__ import annotations

import html
import json
import os
from datetime import datetime, timezone
from pathlib import Path
from string import Template
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent.parent
SITE_DIR = ROOT / "site"
OUTPUT_DIR = ROOT / "_site"
REPO = os.environ.get("GITHUB_REPOSITORY", "mysticalg/Backchat")
PAGES_URL = os.environ.get(
    "BACKCHAT_PAGES_URL",
    f"https://{REPO.split('/')[0]}.github.io/{REPO.split('/')[1]}/",
)
API_TOKEN = os.environ.get("GITHUB_TOKEN", "")

if not PAGES_URL.endswith("/"):
    PAGES_URL = f"{PAGES_URL}/"


PLATFORM_CONFIG = [
    {
        "asset_prefix": "backchat-windows-x64-",
        "suffix": ".zip",
        "label": "Windows",
        "emoji": "Windows",
        "format": "ZIP bundle",
        "description": "Portable Windows build with unread taskbar badges, local history, presence, and desktop calling.",
        "cta": "Download for Windows",
    },
    {
        "asset_prefix": "backchat-macos-",
        "suffix": ".zip",
        "label": "macOS",
        "emoji": "macOS",
        "format": "App bundle ZIP",
        "description": "Desktop macOS release for secure messaging, local chat logs, and direct/VPN-aware calling.",
        "cta": "Download for macOS",
    },
    {
        "asset_prefix": "backchat-linux-x64-",
        "suffix": ".tar.gz",
        "label": "Linux",
        "emoji": "Linux",
        "format": "tar.gz bundle",
        "description": "Linux x64 archive for people who want a straightforward unpack-and-run build.",
        "cta": "Download for Linux",
    },
    {
        "asset_prefix": "backchat-android-",
        "suffix": ".apk",
        "label": "Android APK",
        "emoji": "Android",
        "format": "APK",
        "description": "Direct-install Android package for testing outside the Play Store.",
        "cta": "Download APK",
    },
    {
        "asset_prefix": "backchat-android-",
        "suffix": ".aab",
        "label": "Android App Bundle",
        "emoji": "Play",
        "format": "AAB",
        "description": "Play Store-ready Android App Bundle for publishing and staged rollout workflows.",
        "cta": "Download AAB",
    },
]


def fetch_latest_release() -> dict:
    url = f"https://api.github.com/repos/{REPO}/releases/latest"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "backchat-pages-generator",
    }
    if API_TOKEN:
        headers["Authorization"] = f"Bearer {API_TOKEN}"

    request = Request(url, headers=headers)
    try:
        with urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except HTTPError as exc:
        raise SystemExit(f"Could not fetch latest release ({exc.code}).") from exc
    except URLError as exc:
        raise SystemExit("Could not reach the GitHub API for release data.") from exc


def asset_map(release: dict) -> dict[str, dict]:
    assets = release.get("assets", [])
    mapped: dict[str, dict] = {}
    for platform in PLATFORM_CONFIG:
        asset = next(
            (
                item
                for item in assets
                if item.get("name", "").startswith(platform["asset_prefix"])
                and item.get("name", "").endswith(platform["suffix"])
            ),
            None,
        )
        if asset:
            mapped[platform["label"]] = asset
    return mapped


def human_size(value: int) -> str:
    if value < 1024:
        return f"{value} B"
    units = ["KB", "MB", "GB"]
    size = float(value)
    for unit in units:
        size /= 1024.0
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f} {unit}"
    return f"{size:.1f} GB"


def format_timestamp(raw_value: str) -> str:
    dt = datetime.fromisoformat(raw_value.replace("Z", "+00:00"))
    return dt.astimezone(timezone.utc).strftime("%B %d, %Y")


def build_download_cards(release: dict) -> str:
    assets_by_label = asset_map(release)
    cards: list[str] = []
    for platform in PLATFORM_CONFIG:
        asset = assets_by_label.get(platform["label"])
        if asset is None:
            cards.append(
                f"""
                <article class="download-card unavailable">
                  <div class="download-card__eyebrow">{html.escape(platform["emoji"])}</div>
                  <h3>{html.escape(platform["label"])}</h3>
                  <p>{html.escape(platform["description"])}</p>
                  <div class="download-meta">
                    <span>{html.escape(platform["format"])}</span>
                    <span>Coming soon</span>
                  </div>
                  <div class="download-actions">
                    <span class="button button--muted">Not in latest release</span>
                  </div>
                </article>
                """
            )
            continue

        cards.append(
            f"""
            <article class="download-card">
              <div class="download-card__eyebrow">{html.escape(platform["emoji"])}</div>
              <h3>{html.escape(platform["label"])}</h3>
              <p>{html.escape(platform["description"])}</p>
              <div class="download-meta">
                <span>{html.escape(platform["format"])}</span>
                <span>{human_size(int(asset.get("size", 0)))}</span>
              </div>
              <div class="download-actions">
                <a class="button" href="{html.escape(asset["browser_download_url"])}">{
                    html.escape(platform["cta"])
                }</a>
                <a class="text-link" href="{html.escape(release["html_url"])}">View release notes</a>
              </div>
            </article>
            """
        )
    return "\n".join(cards)


def build_checksum_rows(release: dict) -> str:
    rows: list[str] = []
    for asset in release.get("assets", []):
        digest = asset.get("digest", "")
        sha256_value = digest.split("sha256:", 1)[1] if digest.startswith("sha256:") else "Unavailable"
        rows.append(
            f"""
            <tr>
              <th scope="row">{html.escape(asset.get("name", ""))}</th>
              <td>{html.escape(sha256_value)}</td>
            </tr>
            """
        )
    return "\n".join(rows)


def build_structured_data(release: dict) -> str:
    assets = asset_map(release)
    software_application = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "Backchat",
        "applicationCategory": "CommunicationApplication",
        "operatingSystem": "Windows, macOS, Linux, Android",
        "description": (
            "Backchat is a cross-platform encrypted messenger with local chat history, "
            "presence, unread counters, and direct/VPN-friendly voice and video calling."
        ),
        "url": PAGES_URL,
        "downloadUrl": assets.get("Windows", {}).get("browser_download_url", release.get("html_url", "")),
        "softwareVersion": release.get("name", ""),
        "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
    }
    return json.dumps(software_application, indent=2)


def render_page(release: dict) -> str:
    template = Template((SITE_DIR / "index.template.html").read_text(encoding="utf-8"))
    return template.substitute(
        page_title="Backchat | Secure cross-platform messaging downloads",
        page_description=(
            "Download Backchat for Windows, macOS, Linux, and Android. "
            "A secure messenger with local chat history, unread badges, presence, "
            "and voice/video calling that prefers direct or VPN-friendly routes."
        ),
        canonical_url=PAGES_URL,
        release_name=html.escape(release.get("name", "Latest release")),
        release_tag=html.escape(release.get("tag_name", "")),
        release_date=html.escape(format_timestamp(release.get("published_at", release.get("created_at", "")))),
        release_url=html.escape(release.get("html_url", f"https://github.com/{REPO}/releases")),
        repo_url=html.escape(f"https://github.com/{REPO}"),
        owner_repo=html.escape(REPO),
        download_cards=build_download_cards(release),
        checksum_rows=build_checksum_rows(release),
        generated_at=html.escape(datetime.now(timezone.utc).strftime("%B %d, %Y at %H:%M UTC")),
        structured_data=build_structured_data(release),
    )


def copy_static_file(name: str) -> None:
    source = SITE_DIR / name
    target = OUTPUT_DIR / name
    target.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    release = fetch_latest_release()

    (OUTPUT_DIR / "index.html").write_text(render_page(release), encoding="utf-8")
    (OUTPUT_DIR / "404.html").write_text(render_page(release), encoding="utf-8")
    (OUTPUT_DIR / ".nojekyll").write_text("", encoding="utf-8")
    copy_static_file("styles.css")
    copy_static_file("robots.txt")

    sitemap = f"""<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>{html.escape(PAGES_URL)}</loc>
    <lastmod>{datetime.now(timezone.utc).date().isoformat()}</lastmod>
  </url>
</urlset>
"""
    (OUTPUT_DIR / "sitemap.xml").write_text(sitemap, encoding="utf-8")


if __name__ == "__main__":
    main()
