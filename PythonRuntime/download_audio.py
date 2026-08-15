import json
import os
import pathlib
import time
import traceback


def _write_json(path, value):
    temporary = f"{path}.tmp"
    with open(temporary, "w", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False)
    os.replace(temporary, path)


def download_audio(url, output_directory, cancellation_path, progress_path):
    """Download a public YouTube video's M4A-only stream and return JSON."""
    try:
        import yt_dlp

        output_root = pathlib.Path(output_directory)
        output_root.mkdir(parents=True, exist_ok=True)
        last_progress_write = 0.0

        def progress_hook(status):
            nonlocal last_progress_write
            if os.path.exists(cancellation_path):
                raise yt_dlp.utils.DownloadCancelled("cancel requested")
            current_time = time.monotonic()
            is_finished = status.get("status") == "finished"
            # yt-dlp may invoke this hook thousands of times per second. The
            # Swift UI polls at 4 Hz, so writing an atomic JSON file for every
            # callback only amplifies SSD writes without improving the UI.
            if not is_finished and current_time - last_progress_write < 0.25:
                return
            last_progress_write = current_time
            total = status.get("total_bytes") or status.get("total_bytes_estimate") or 0
            downloaded = status.get("downloaded_bytes") or 0
            fraction = (downloaded / total) if total else 0.0
            if is_finished:
                fraction = 1.0
            _write_json(progress_path, {
                "fraction": max(0.0, min(1.0, fraction)),
                "downloaded_bytes": downloaded,
                "total_bytes": total,
                "status": status.get("status", "downloading"),
            })

        options = {
            "format": "bestaudio[ext=m4a][vcodec=none]",
            "outtmpl": str(output_root / "%(id)s.%(ext)s"),
            "noplaylist": True,
            "overwrites": True,
            "continuedl": False,
            "nopart": False,
            "quiet": True,
            "no_warnings": False,
            "progress_hooks": [progress_hook],
            "cachedir": str(output_root / ".cache"),
            "socket_timeout": 30,
            "retries": 3,
        }

        with yt_dlp.YoutubeDL(options) as downloader:
            info = downloader.extract_info(url, download=True)
            requested = info.get("requested_downloads") or []
            selected = requested[0] if requested else info
            filepath = selected.get("filepath") or downloader.prepare_filename(info)

        path = pathlib.Path(filepath)
        if path.suffix.lower() != ".m4a" or not path.exists():
            raise RuntimeError("M4A audio format is unavailable for this video")

        return json.dumps({
            "success": True,
            "path": str(path),
            "video_id": info.get("id", ""),
            "title": info.get("title", ""),
            "duration": info.get("duration") or 0,
            "thumbnail": info.get("thumbnail"),
            "channel": info.get("channel") or info.get("uploader") or "",
        }, ensure_ascii=False)
    except BaseException as error:
        cancelled = os.path.exists(cancellation_path) or "cancel requested" in str(error).lower()
        return json.dumps({
            "success": False,
            "cancelled": cancelled,
            "error": str(error),
            "traceback": traceback.format_exc(),
        }, ensure_ascii=False)
