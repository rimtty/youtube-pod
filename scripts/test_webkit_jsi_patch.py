#!/usr/bin/env python3
"""Host-side regression test for the patched yt-dlp WebKit JS runtime.

Runs on macOS against the real yt-dlp-apple-webkit-jsi plugin from
PythonRuntime/site-packages (pure Python + ctypes, so the same code that ships
in the app). It proves two things without a device:

1. The patched navigation delegate cancels a script-initiated navigation to
   youtube.com (the exact statement yt-dlp-ejs runs), the document stays at
   about:blank, and the webview keeps executing JavaScript afterwards.
2. The patched yt-dlp-ejs core script contains the location guard and its
   SHA3-512 digest matches the one yt-dlp will verify it against, so yt-dlp
   accepts the patched solver instead of silently rejecting it.

Set YOUTUBEPOD_SKIP_WEBKIT_HOST_TEST=1 to skip the WebKit half on hosts that
cannot create a WKWebView.
"""

from __future__ import annotations

import hashlib
import os
import platform
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SITE_PACKAGES = PROJECT_ROOT / "PythonRuntime" / "site-packages"
sys.path.insert(0, str(SITE_PACKAGES))

YOUTUBE_URL = "https://www.youtube.com/watch?v=yt-dlp-wins"
CANCEL_MESSAGE = f"Cancelled navigation to {YOUTUBE_URL}"
LOCATION_GUARD = '} else if (typeof globalThis.location === "undefined") {'


def fail(message: str) -> None:
    raise SystemExit(f"test_webkit_jsi_patch: FAIL: {message}")


def test_solver_script_is_patched_and_accepted() -> None:
    import yt_dlp_ejs.yt.solver
    from yt_dlp.extractor.youtube.jsc._builtin.vendor._info import HASHES

    core = yt_dlp_ejs.yt.solver.core()
    if LOCATION_GUARD not in core:
        fail("yt_dlp_ejs core script does not contain the location guard")
    if "} else {\\n    globalThis.location" in core:
        fail("yt_dlp_ejs core script still assigns globalThis.location unconditionally")
    digest = hashlib.sha3_512(core.encode("utf-8")).hexdigest()
    if HASHES["yt.solver.core.min.js"] != digest:
        fail("yt-dlp's allowed hash for yt.solver.core.min.js does not match the patched script")
    print("ok: yt-dlp-ejs core script is guarded and its digest is accepted by yt-dlp")


def test_webview_cancels_navigation() -> None:
    from yt_dlp_plugins.webkit_jsi.lib.easy import WKJSE_Factory, WKJSE_Webview
    from yt_dlp_plugins.webkit_jsi.lib.logging import AbstractLogger

    class RecordingLogger(AbstractLogger):
        def __init__(self) -> None:
            self.messages: list[str] = []

        def trace(self, message: str) -> None:
            self.messages.append(message)

        def debug(self, message: str, *, once=False) -> None:
            self.messages.append(message)

        def info(self, message: str) -> None:
            self.messages.append(message)

        def warning(self, message: str, *, once=False) -> None:
            self.messages.append(message)

        def error(self, message: str, *, cause=None) -> None:
            self.messages.append(message)

    logger = RecordingLogger()
    console: list[str] = []

    def on_log(message) -> None:
        # {logType, argsArr} as posted by the plugin's console shim.
        console.extend(str(arg) for arg in message["argsArr"])

    def location_href(webview: WKJSE_Webview) -> str:
        console.clear()
        webview.execute_js("console.log(location.href);")
        return console[-1] if console else "<no output>"

    with WKJSE_Factory(logger) as send, WKJSE_Webview(send) as webview:
        webview.on_script_log(on_log)

        before = location_href(webview)
        if before != "about:blank":
            fail(f"fresh webview should be at about:blank, got {before!r}")

        # The statement yt-dlp-ejs executes during environment setup.
        webview.execute_js(f'globalThis.location = new URL("{YOUTUBE_URL}");')

        # The policy decision arrives asynchronously; each execute_js call spins
        # the run loop while waiting, which delivers the delegate callback.
        cancelled = False
        for _ in range(40):
            webview.execute_js("await new Promise(resolve => setTimeout(resolve, 50));")
            if any(CANCEL_MESSAGE in message for message in logger.messages):
                cancelled = True
                break
        if not cancelled:
            fail("navigation delegate never reported cancelling the youtube.com navigation")

        after = location_href(webview)
        if after != "about:blank":
            fail(f"document navigated away from about:blank: {after!r}")

        console.clear()
        # Numbers cross the ObjC bridge as doubles, so compare a string.
        webview.execute_js('console.log("alive:" + (40 + 2));')
        if console[-1:] != ["alive:42"]:
            fail(f"webview stopped executing JavaScript after the cancelled navigation: {console!r}")

    print("ok: patched delegate cancelled the youtube.com navigation and the webview stayed usable")

    # The plugin's own navigate_to (loadHTMLString:baseURL:) must still be
    # allowed through the delegate, otherwise it would wait forever for
    # didFinishNavigation.
    with WKJSE_Factory(logger) as send, WKJSE_Webview(send) as webview:
        webview.on_script_log(on_log)
        webview.navigate_to(YOUTUBE_URL, "<!DOCTYPE html><html><head><title></title></head><body></body></html>")
        loaded = location_href(webview)
        if loaded != YOUTUBE_URL:
            fail(f"navigate_to should be allowed by the delegate; location is {loaded!r}")
    print("ok: navigate_to (loadHTMLString:baseURL:) is still allowed")


def main() -> int:
    test_solver_script_is_patched_and_accepted()
    if os.environ.get("YOUTUBEPOD_SKIP_WEBKIT_HOST_TEST") == "1":
        print("skip: WebKit host test disabled by YOUTUBEPOD_SKIP_WEBKIT_HOST_TEST=1")
        return 0
    if platform.system() != "Darwin":
        print("skip: WebKit host test requires macOS")
        return 0
    test_webview_cancels_navigation()
    return 0


if __name__ == "__main__":
    sys.exit(main())
