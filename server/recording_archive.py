"""Persistent recording storage for the Windows Voice server."""

import hashlib
import os
import re
import shutil
from pathlib import Path
from uuid import uuid4

from fastapi import HTTPException, Request
from fastapi.responses import FileResponse
from starlette.concurrency import run_in_threadpool


def install_recording_archive(app, directory: Path, minimum_free: int):
    directory.mkdir(parents=True, exist_ok=True)
    for partial in directory.glob("*.partial"):
        partial.unlink(missing_ok=True)

    def archive_path(digest: str):
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise HTTPException(404)
        return directory / f"{digest}.m4a"

    @app.get("/api/mobile/recording-archive")
    def archive_status():
        return {"version": 1}

    @app.put("/api/mobile/recording-archive/{digest}")
    async def save_recording(digest: str, request: Request):
        path = archive_path(digest)
        try:
            length = int(request.headers.get("content-length", "0"))
        except ValueError:
            raise HTTPException(400, "Invalid content length") from None
        if not 0 < length <= 1024**3:
            raise HTTPException(413, "Recording must be at most 1 GiB")

        def existing_matches():
            try:
                with path.open("rb") as source:
                    return path.stat().st_size == length and hashlib.file_digest(source, "sha256").hexdigest() == digest
            except FileNotFoundError:
                return False

        receipt = {"sha256": digest, "bytes": length}
        if await run_in_threadpool(existing_matches):
            return receipt
        if shutil.disk_usage(directory).free < minimum_free + length:
            raise HTTPException(507, "Windows PC storage is full")
        temp = directory / f"{uuid4().hex}.partial"
        try:
            checksum = hashlib.sha256()
            size = 0
            with temp.open("xb") as output:
                async for chunk in request.stream():
                    size += len(chunk)
                    if size > length:
                        raise HTTPException(413, "Recording exceeds declared length")
                    checksum.update(chunk)
                    await run_in_threadpool(output.write, chunk)
                if size != length or checksum.hexdigest() != digest:
                    raise HTTPException(422, "Recording checksum does not match")
                await run_in_threadpool(output.flush)
                await run_in_threadpool(os.fsync, output.fileno())
            os.replace(temp, path)
            return receipt
        finally:
            temp.unlink(missing_ok=True)

    @app.get("/api/mobile/recording-archive/{digest}")
    def load_recording(digest: str):
        path = archive_path(digest)
        if not path.is_file():
            raise HTTPException(404, "Recording was not found on the Windows PC")
        return FileResponse(path, media_type="audio/mp4", headers={"Cache-Control": "no-store"})
