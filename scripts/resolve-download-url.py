#!/usr/bin/env python3
"""
Resolve Claude Desktop download URLs by bypassing Cloudflare protection.

Uses Playwright to navigate to the redirect URL and capture the final
download URL from network requests.
"""

import argparse
import re
import sys

import requests
from playwright.sync_api import sync_playwright, TimeoutError as PlaywrightTimeout


# Redirect URLs for each architecture
REDIRECT_URLS = {
    "amd64": "https://claude.ai/redirect/claudedotcom.v1.290130bf-1c36-4eb0-9a93-2410ca43ae53/api/desktop/win32/x64/exe/latest/redirect",
    "arm64": "https://claude.ai/redirect/claudedotcom.v1.290130bf-1c36-4eb0-9a93-2410ca43ae53/api/desktop/win32/arm64/exe/latest/redirect",
}

# User agent to appear as a regular browser
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"


def resolve_download_url(arch: str, timeout: int = 30000) -> str | None:
    """
    Resolve the actual download URL for the given architecture.

    Args:
        arch: Architecture to resolve ('amd64' or 'arm64')
        timeout: Timeout in milliseconds

    Returns:
        The resolved download URL, or None if resolution failed
    """
    if arch not in REDIRECT_URLS:
        print(f"Error: Unknown architecture '{arch}'", file=sys.stderr)
        return None

    redirect_url = REDIRECT_URLS[arch]
    resolved_url = None

    def handle_request(request):
        nonlocal resolved_url
        url = request.url
        # Look for the final Google Cloud Storage URL
        if "storage.googleapis.com" in url and url.endswith(".exe"):
            resolved_url = url

    def handle_download(download):
        nonlocal resolved_url
        resolved_url = download.url

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent=USER_AGENT,
            viewport={"width": 1920, "height": 1080},
            accept_downloads=True,
        )

        # Apply stealth settings
        context.add_init_script("""
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'platform', { get: () => 'Linux x86_64' });
            Object.defineProperty(navigator, 'vendor', { get: () => 'Google Inc.' });
        """)

        page = context.new_page()
        page.on("request", handle_request)
        page.on("download", handle_download)

        try:
            # Navigate to the redirect URL - this will trigger a download
            page.goto(redirect_url, timeout=timeout, wait_until="commit")
            # Give it a moment to capture the download URL
            page.wait_for_timeout(2000)
        except PlaywrightTimeout:
            # Timeout is expected - we just need to capture the redirect
            pass
        except Exception as e:
            # "Download is starting" error is expected and means we captured the URL
            if "Download is starting" not in str(e):
                print(f"Error navigating to {redirect_url}: {e}", file=sys.stderr)
        finally:
            browser.close()

    return resolved_url


def extract_version_from_url(url: str) -> str | None:
    """
    Extract version number from a download URL.

    The URL typically contains a path like /1.0.1234/ with the version.
    """
    match = re.search(r"/(\d+\.\d+\.\d+)/", url)
    if match:
        return match.group(1)
    return None


def verify_url_exists(url: str, timeout: int = 10) -> bool:
    """
    Verify that a URL exists by making a HEAD request.

    Returns True if the URL returns a 200 status code.
    """
    try:
        response = requests.head(url, timeout=timeout, allow_redirects=True)
        return response.status_code == 200
    except requests.RequestException:
        return False


def derive_mac_url_from_amd64(amd64_url: str) -> str | None:
    """
    Derive the macOS universal DMG URL from an AMD64 Windows URL.

    Pattern: /win32/x64/VERSION/Claude-COMMIT.exe -> /darwin/universal/VERSION/Claude-COMMIT.dmg
    """
    if not amd64_url:
        return None

    mac_url = amd64_url
    mac_url = mac_url.replace("/win32/x64/", "/darwin/universal/")
    mac_url = re.sub(r'\.exe$', '.dmg', mac_url)

    if mac_url != amd64_url:
        return mac_url
    return None


def derive_arm64_url_from_amd64(amd64_url: str) -> str | None:
    """
    Derive the ARM64 download URL from an AMD64 URL by pattern substitution.

    Handles both old and new URL patterns:
    Old: https://storage.googleapis.com/.../nest-win-x64/Claude-Setup-x64.exe
    New: https://downloads.claude.ai/releases/win32/x64/1.0.xxx/Claude-xxx.exe
    """
    if not amd64_url:
        return None

    arm64_url = amd64_url

    # New URL pattern: downloads.claude.ai/releases/win32/x64/ -> /arm64/
    arm64_url = arm64_url.replace("/win32/x64/", "/win32/arm64/")

    # Old URL pattern: storage.googleapis.com
    arm64_url = arm64_url.replace("nest-win-x64", "nest-win-arm64")
    arm64_url = arm64_url.replace("Claude-Setup-x64.exe", "Claude-Setup-arm64.exe")
    arm64_url = arm64_url.replace("-x64.exe", "-arm64.exe")

    # Only return if we actually made changes
    if arm64_url != amd64_url:
        return arm64_url
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Resolve Claude Desktop download URLs"
    )
    parser.add_argument(
        "arch",
        choices=["amd64", "arm64", "all"],
        help="Architecture to resolve (amd64, arm64, or all)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=30000,
        help="Timeout in milliseconds (default: 30000)",
    )
    parser.add_argument(
        "--format",
        choices=["url", "version", "both"],
        default="url",
        help="Output format (default: url)",
    )

    args = parser.parse_args()

    architectures = ["amd64", "arm64"] if args.arch == "all" else [args.arch]

    results = {}
    for arch in architectures:
        print(f"Resolving {arch} download URL...", file=sys.stderr)
        url = resolve_download_url(arch, args.timeout)

        if url:
            version = extract_version_from_url(url)
            results[arch] = {"url": url, "version": version, "derived": False}
            print(f"  Resolved: {url}", file=sys.stderr)
            if version:
                print(f"  Version: {version}", file=sys.stderr)
        else:
            print(f"  Failed to resolve {arch} URL via redirect", file=sys.stderr)
            results[arch] = None

    # If ARM64 failed but AMD64 succeeded, try to derive ARM64 URL
    if args.arch == "all" and results.get("arm64") is None and results.get("amd64"):
        print("Attempting to derive ARM64 URL from AMD64 URL...", file=sys.stderr)
        derived_url = derive_arm64_url_from_amd64(results["amd64"]["url"])
        if derived_url:
            print(f"  Derived URL: {derived_url}", file=sys.stderr)
            print("  Verifying URL exists...", file=sys.stderr)
            if verify_url_exists(derived_url):
                version = extract_version_from_url(derived_url)
                results["arm64"] = {"url": derived_url, "version": version, "derived": True}
                print(f"  ✓ Verified ARM64 URL exists", file=sys.stderr)
            else:
                print("  ✗ Derived URL does not exist (404)", file=sys.stderr)
        else:
            print("  Could not derive ARM64 URL pattern", file=sys.stderr)

    # Derive macOS universal URL from AMD64 URL and output it
    if args.arch == "all" and results.get("amd64"):
        mac_url = derive_mac_url_from_amd64(results["amd64"]["url"])
        if mac_url:
            if verify_url_exists(mac_url):
                print(f"Derived macOS URL: {mac_url} (verified)", file=sys.stderr)
                if args.format in ("url", "both"):
                    print(f"MAC_URL={mac_url}")
            else:
                print("Derived macOS URL does not exist (404)", file=sys.stderr)
        else:
            print("Could not derive macOS URL from AMD64 URL", file=sys.stderr)

    # Output results based on format
    for arch, result in results.items():
        if result is None:
            continue

        prefix = f"{arch.upper()}_" if len(architectures) > 1 else ""

        if args.format == "url":
            print(f"{prefix}URL={result['url']}")
        elif args.format == "version":
            if result["version"]:
                print(f"{prefix}VERSION={result['version']}")
        elif args.format == "both":
            print(f"{prefix}URL={result['url']}")
            if result["version"]:
                print(f"{prefix}VERSION={result['version']}")

    # Exit with error if any resolution failed
    if any(r is None for r in results.values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
