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
SITE_URL = os.environ.get(
    "BACKCHAT_SITE_URL",
    os.environ.get(
        "BACKCHAT_PAGES_URL",
        f"https://{REPO.split('/')[0]}.github.io/{REPO.split('/')[1]}/",
    ),
)
API_TOKEN = os.environ.get("GITHUB_TOKEN", "")

if not SITE_URL.endswith("/"):
    SITE_URL = f"{SITE_URL}/"


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
        "url": SITE_URL,
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
        canonical_url=SITE_URL,
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


def render_legal_page(
    *,
    title: str,
    description: str,
    canonical_url: str,
    article_title: str,
    effective_date: str,
    body_html: str,
) -> str:
    template = Template((SITE_DIR / "legal.template.html").read_text(encoding="utf-8"))
    return template.substitute(
        page_title=title,
        page_description=description,
        canonical_url=canonical_url,
        article_title=article_title,
        effective_date=effective_date,
        body_html=body_html,
    )


def copy_static_file(name: str) -> None:
    source = SITE_DIR / name
    target = OUTPUT_DIR / name
    target.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")


def privacy_body() -> str:
    return """
    <section class="legal-section">
      <h2>Overview</h2>
      <p>
        This Privacy Policy explains what information Backchat collects, where it is stored, and how it is used.
        It is written for the app and download site in their current state as of the effective date below.
      </p>
    </section>
    <section class="legal-section">
      <h2>Information you provide</h2>
      <p>Depending on which features you use, Backchat may store:</p>
      <ul>
        <li>Your username and normalized username.</li>
        <li>Your recovery email address for username-based account recovery.</li>
        <li>Your avatar URL and profile quote if you choose to set them.</li>
        <li>Contact relationships you create inside the app.</li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>Messages, call data, and local history</h2>
      <ul>
        <li>
          Message history and unread counts are cached locally on each device or computer using the app.
        </li>
        <li>
          The current backend stores message ciphertext and basic delivery metadata such as sender, recipient,
          timestamps, and client message IDs.
        </li>
        <li>
          Voice and video calling uses WebRTC-style signaling. The backend stores call session records and signaling
          events needed to set up calls.
        </li>
        <li>
          Call media is intended to use direct peer-to-peer paths where possible, but call setup still requires
          signaling and network metadata.
        </li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>Session, security, and technical data</h2>
      <ul>
        <li>Session tokens are issued for signed-in users and stored server-side as token hashes.</li>
        <li>Presence information is derived from session activity timestamps.</li>
        <li>
          If social sign-in is enabled in the future, Backchat may store provider identity data, profile data, and
          OAuth tokens needed for that feature.
        </li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>Website and download hosting</h2>
      <p>
        The public download site is hosted on GitHub Pages and release files are hosted on GitHub Releases.
        GitHub may collect standard web server and download request information such as IP address, user agent,
        request timestamps, and referrer data under GitHub&apos;s own terms and privacy practices.
      </p>
    </section>
    <section class="legal-section">
      <h2>How information is used</h2>
      <ul>
        <li>To create and recover username-based accounts.</li>
        <li>To display your profile, presence, and contact list.</li>
        <li>To route encrypted messages and call signaling between users.</li>
        <li>To keep local conversation history and unread counters on your device.</li>
        <li>To provide download pages and release assets.</li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>Sharing</h2>
      <p>
        Backchat does not sell your personal information. Data may be processed through infrastructure providers used
        to operate the project, including GitHub for the public site and releases and AWS for the hosted API.
      </p>
    </section>
    <section class="legal-section">
      <h2>Retention</h2>
      <p>
        Local chat history stays on the device where it was stored unless you remove it locally. Server-side records
        may remain until deleted, rotated, or removed as part of maintenance or account cleanup.
      </p>
    </section>
    <section class="legal-section">
      <h2>Your choices</h2>
      <ul>
        <li>You can choose whether to set an avatar URL or profile quote.</li>
        <li>You can decide whether to install and keep local conversation history on a given device.</li>
        <li>You can stop using the app at any time.</li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>No special-category or emergency use promise</h2>
      <p>
        Backchat is not offered as a medical, legal, financial, child-directed, or emergency communications service.
        Do not rely on it for emergencies or safety-critical communication.
      </p>
    </section>
    <section class="legal-section">
      <h2>Contact</h2>
      <p>
        For project or privacy questions, use the GitHub repository issue tracker unless and until a dedicated support
        address is published.
      </p>
    </section>
    """


def terms_body() -> str:
    return """
    <section class="legal-section">
      <h2>Acceptance</h2>
      <p>
        By downloading, installing, accessing, or using Backchat or its download site, you agree to these Terms and
        Conditions.
      </p>
    </section>
    <section class="legal-section">
      <h2>What Backchat is</h2>
      <p>
        Backchat is a software project for messaging, presence, and voice/video calling. It is currently distributed
        as software releases through GitHub and uses hosted infrastructure for account, message, and call-signaling
        features.
      </p>
    </section>
    <section class="legal-section">
      <h2>License and permitted use</h2>
      <p>
        You may use the released app and site for lawful personal or internal testing use unless a separate license or
        repository license file states otherwise. You must not use Backchat to violate laws, infringe rights, harass
        others, distribute malware, or interfere with the service.
      </p>
    </section>
    <section class="legal-section">
      <h2>Your content and responsibilities</h2>
      <ul>
        <li>You are responsible for the usernames, profile text, avatar URLs, messages, and call activity you initiate.</li>
        <li>You must only use content and profile images you have the right to use.</li>
        <li>You must not attempt to access accounts, sessions, or data that are not yours.</li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>Availability and changes</h2>
      <p>
        Backchat is provided on an evolving basis. Features may change, break, be removed, or become unavailable at
        any time without notice, including hosted API features, downloads, or calling functionality.
      </p>
    </section>
    <section class="legal-section">
      <h2>No warranty</h2>
      <p>
        Backchat is provided &quot;as is&quot; and &quot;as available&quot; without warranties of any kind, whether express or implied,
        including merchantability, fitness for a particular purpose, non-infringement, or uninterrupted availability.
      </p>
    </section>
    <section class="legal-section">
      <h2>Limitation of liability</h2>
      <p>
        To the maximum extent permitted by law, the project owner and contributors will not be liable for indirect,
        incidental, special, consequential, exemplary, or punitive damages, or for loss of data, profits, goodwill,
        or business interruption arising from use of or inability to use Backchat.
      </p>
    </section>
    <section class="legal-section">
      <h2>Security and backups</h2>
      <p>
        You are responsible for maintaining your own device security, backup practices, and safe handling of your
        account details. Local conversation history may be lost if your device is reset, damaged, or cleaned.
      </p>
    </section>
    <section class="legal-section">
      <h2>No emergency or regulated-service use</h2>
      <p>
        Backchat is not an emergency service and is not guaranteed for regulated, life-critical, or compliance-critical
        communications.
      </p>
    </section>
    <section class="legal-section">
      <h2>Third-party services</h2>
      <p>
        Backchat may rely on third-party services including GitHub and AWS. Their separate terms, policies, and
        service limitations may also apply.
      </p>
    </section>
    <section class="legal-section">
      <h2>Changes to these terms</h2>
      <p>
        These Terms may be updated over time. Continued use after updated terms are published means you accept the
        revised version.
      </p>
    </section>
    <section class="legal-section">
      <h2>Contact</h2>
      <p>
        For project questions, bug reports, or policy concerns, use the GitHub issue tracker unless a dedicated
        support channel is published later.
      </p>
    </section>
    """


def delete_account_body() -> str:
    return """
    <section class="legal-section">
      <h2>Request account deletion</h2>
      <p>
        To request deletion of your Backchat account and associated hosted data, open a support request through the
        Backchat GitHub repository and include the username tied to the account you want deleted.
      </p>
      <p>
        Support URL:
        <a href="https://github.com/mysticalg/Backchat/issues">https://github.com/mysticalg/Backchat/issues</a>
      </p>
    </section>
    <section class="legal-section">
      <h2>What to include</h2>
      <ul>
        <li>Your Backchat username.</li>
        <li>The recovery email address connected to that username, if you still have access to it.</li>
        <li>A short note saying you are requesting account deletion.</li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>What will be deleted</h2>
      <ul>
        <li>Hosted account profile data such as username, recovery email, avatar URL, and quote.</li>
        <li>Hosted contact relationships connected to the account.</li>
        <li>Hosted session records and account-linked call signaling records that can be removed as part of cleanup.</li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>What may remain temporarily</h2>
      <ul>
        <li>Operational logs, backups, and security records may remain for a limited retention period before rotation.</li>
        <li>Conversation history cached locally on devices is not automatically removed from other users' computers.</li>
        <li>Messages already delivered to another user may remain in that user's local history.</li>
      </ul>
    </section>
    <section class="legal-section">
      <h2>Optional data deletion without account deletion</h2>
      <p>
        Backchat does not currently offer a separate self-service tool to delete only part of your hosted data while
        keeping the account active. If this changes, this page will be updated.
      </p>
    </section>
    """


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    release = fetch_latest_release()

    (OUTPUT_DIR / "index.html").write_text(render_page(release), encoding="utf-8")
    (OUTPUT_DIR / "404.html").write_text(render_page(release), encoding="utf-8")
    (OUTPUT_DIR / "privacy.html").write_text(
        render_legal_page(
            title="Backchat Privacy Policy",
            description=(
                "Read the Backchat Privacy Policy, including what data is stored on-device, "
                "what the hosted backend retains, and how downloads are served."
            ),
            canonical_url=f"{SITE_URL}privacy.html",
            article_title="Privacy Policy",
            effective_date="March 18, 2026",
            body_html=privacy_body(),
        ),
        encoding="utf-8",
    )
    (OUTPUT_DIR / "terms.html").write_text(
        render_legal_page(
            title="Backchat Terms and Conditions",
            description=(
                "Read the Backchat Terms and Conditions for downloads, hosted features, "
                "acceptable use, and the current as-is software disclaimer."
            ),
            canonical_url=f"{SITE_URL}terms.html",
            article_title="Terms and Conditions",
            effective_date="March 18, 2026",
            body_html=terms_body(),
        ),
        encoding="utf-8",
    )
    (OUTPUT_DIR / "delete-account.html").write_text(
        render_legal_page(
            title="Backchat Account Deletion",
            description=(
                "Request deletion of your Backchat account and associated hosted data, "
                "including what is deleted, what may remain temporarily, and how to contact support."
            ),
            canonical_url=f"{SITE_URL}delete-account.html",
            article_title="Account Deletion",
            effective_date="March 19, 2026",
            body_html=delete_account_body(),
        ),
        encoding="utf-8",
    )
    (OUTPUT_DIR / ".nojekyll").write_text("", encoding="utf-8")
    copy_static_file("styles.css")
    (OUTPUT_DIR / "robots.txt").write_text(
        f"User-agent: *\nAllow: /\n\nSitemap: {SITE_URL}sitemap.xml\n",
        encoding="utf-8",
    )

    sitemap = f"""<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>{html.escape(SITE_URL)}</loc>
    <lastmod>{datetime.now(timezone.utc).date().isoformat()}</lastmod>
  </url>
  <url>
    <loc>{html.escape(f"{SITE_URL}privacy.html")}</loc>
    <lastmod>{datetime.now(timezone.utc).date().isoformat()}</lastmod>
  </url>
  <url>
    <loc>{html.escape(f"{SITE_URL}terms.html")}</loc>
    <lastmod>{datetime.now(timezone.utc).date().isoformat()}</lastmod>
  </url>
  <url>
    <loc>{html.escape(f"{SITE_URL}delete-account.html")}</loc>
    <lastmod>{datetime.now(timezone.utc).date().isoformat()}</lastmod>
  </url>
</urlset>
"""
    (OUTPUT_DIR / "sitemap.xml").write_text(sitemap, encoding="utf-8")


if __name__ == "__main__":
    main()
