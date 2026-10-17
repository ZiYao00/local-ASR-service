"""Regression tests for request cancellation, queue ownership, and temp cleanup.

Runs without loading the ASR or forced-alignment models and without touching the
already-running service on the configured port.
"""
from __future__ import annotations

import asyncio
import io
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

import httpx
from fastapi import HTTPException, UploadFile

from service import app as service


class RequestLifecycleTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.original_queue = service.QUEUE
        self.original_running = service.RUNNING
        self.original_waiting = service.WAITING
        service.QUEUE = asyncio.Semaphore(1)
        service.RUNNING = 0
        service.WAITING = 0

    def tearDown(self) -> None:
        self.assertEqual(service.RUNNING, 0, "A job did not release its queue slot")
        self.assertEqual(service.WAITING, 0, "A job remained waiting")
        service.QUEUE = self.original_queue
        service.RUNNING = self.original_running
        service.WAITING = self.original_waiting

    def staged_file(self) -> Path:
        fd, name = tempfile.mkstemp(
            prefix="local-asr-lifecycle-test-",
            suffix=".wav",
            dir=service.CONFIG["temp_dir"],
        )
        os.close(fd)
        file_path = Path(name)
        file_path.write_bytes(b"test-only media")
        self.addCleanup(file_path.unlink, missing_ok=True)
        return file_path

    def upload_files(self) -> set[str]:
        return {
            p.name for p in Path(service.CONFIG["temp_dir"]).iterdir()
            if p.is_file() and p.name.startswith("local-asr-upload-")
        }

    async def until(self, predicate, *, tries: int = 250) -> None:
        for _ in range(tries):
            if predicate():
                return
            await asyncio.sleep(0.01)
        self.fail("Timed out waiting for asynchronous lifecycle state")

    async def test_upload_cancel_removes_partial_file(self) -> None:
        prior = self.upload_files()
        upload = AsyncMock()
        upload.read.side_effect = [b"partial", asyncio.CancelledError()]
        with self.assertRaises(asyncio.CancelledError):
            await service._save_upload(upload, ".wav")
        self.assertEqual(prior, self.upload_files())

    async def test_oversized_file_rejected_and_cleaned(self) -> None:
        prior = self.upload_files()
        upload = UploadFile(filename="too-big.wav", file=io.BytesIO(b"12345"))
        with patch.dict(service.CONFIG, {"max_upload_bytes": 3, "upload_chunk_bytes": 2}):
            with self.assertRaises(HTTPException) as raised:
                await service._save_upload(upload, ".wav")
        self.assertEqual(raised.exception.status_code, 413)
        self.assertEqual(prior, self.upload_files())
        await upload.close()

    async def test_waiting_request_cancellation_releases_resources(self) -> None:
        service.QUEUE = asyncio.Semaphore(0)
        staged = self.staged_file()

        async def operation():
            self.fail("A cancelled waiting request started inference")

        caller = asyncio.create_task(service._execute_queued(operation, staged))
        await self.until(lambda: service.WAITING == 1)
        caller.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await caller
        await self.until(lambda: service.WAITING == 0 and not staged.exists())
        self.assertEqual(service.RUNNING, 0)

    async def test_cancelled_active_request_keeps_queue_until_thread_finishes(self) -> None:
        started = threading.Event()
        finish = threading.Event()
        staged_one = self.staged_file()
        staged_two = self.staged_file()

        def blocking_inference():
            started.set()
            if not finish.wait(5):
                raise TimeoutError("Synthetic test worker was not released")
            return {"text": "first"}

        async def first_operation():
            return await asyncio.to_thread(blocking_inference)

        async def second_operation():
            return {"text": "second"}

        first = asyncio.create_task(service._execute_queued(first_operation, staged_one))
        try:
            await self.until(started.is_set)
            first.cancel()
            with self.assertRaises(asyncio.CancelledError):
                await first
            self.assertTrue(staged_one.exists())
            self.assertEqual(service.RUNNING, 1)

            second = asyncio.create_task(service._execute_queued(second_operation, staged_two))
            await self.until(lambda: service.WAITING == 1)
            self.assertFalse(second.done())
            self.assertEqual(service.RUNNING, 1)

            finish.set()
            self.assertEqual((await asyncio.wait_for(second, 5))["text"], "second")
            await self.until(lambda: service.RUNNING == 0 and not staged_one.exists())
            self.assertFalse(staged_two.exists())
        finally:
            finish.set()

    async def test_timeout_releases_waiting_counter_and_file(self) -> None:
        service.QUEUE = asyncio.Semaphore(0)
        staged = self.staged_file()

        async def operation():
            self.fail("Timed-out request should not run")

        with patch.dict(service.CONFIG, {"queue_timeout_seconds": 0.02}):
            with self.assertRaises(HTTPException) as raised:
                await service._execute_queued(operation, staged)
        self.assertEqual(raised.exception.status_code, 503)
        self.assertFalse(staged.exists())

    async def test_normal_transcription_keeps_api_shape(self) -> None:
        prior = self.upload_files()
        upload = UploadFile(filename="sample.wav", file=io.BytesIO(b"fake wav"))

        def fake_transcribe(path, language):
            self.assertTrue(path.exists())
            self.assertEqual(language, "zh")
            return {"status": "ok", "text": "sample", "segments": [], "segments_punctuated": False}

        with patch.object(service.ENGINE, "transcribe", side_effect=fake_transcribe):
            result = await service.transcribe(
                file=upload, model="custom", language="zh", response_format="verbose_json"
            )
        self.assertEqual(result.status_code, 200)
        self.assertEqual(json.loads(result.body)["text"], "sample")
        self.assertEqual(prior, self.upload_files())

    async def test_normal_alignment_keeps_api_shape(self) -> None:
        prior = self.upload_files()
        upload = UploadFile(filename="sample.wav", file=io.BytesIO(b"fake wav"))
        alignment_result = {
            "items": [{"text": "hello", "start": 0.0, "end": 1.0}],
            "aligned_units": 1,
            "audio_duration_seconds": 1.0,
            "model_load_seconds": 0.1,
            "alignment_seconds": 0.2,
            "total_seconds": 0.3,
        }
        with (
            patch.object(service, "forced_aligner_status", return_value={"ready": True}),
            patch.object(service.ENGINE, "transcribe", return_value={"text": "hello"}),
            patch.object(service.ENGINE, "normalize_media", side_effect=lambda p: (p, None)),
            patch.object(service, "run_forced_alignment", return_value=alignment_result),
            patch.object(service, "segment_aligned_transcript", return_value=[{"start": 0.0, "end": 1.0, "text": "hello"}]),
            patch.object(service, "summarize_cues", return_value={"cue_count": 1}),
            patch.object(service, "format_srt", return_value="1\\r\\n00:00:00,000 --> 00:00:01,000\\r\\nhello"),
        ):
            result = await service.align_audio(
                file=upload, transcript="hello", language="zh", preset="voiceover"
            )
        payload = json.loads(result.body)
        self.assertEqual(result.status_code, 200)
        self.assertEqual(payload["script_match"]["status"], "pass")
        self.assertEqual(payload["aligned_units"], 1)
        self.assertEqual(payload["subtitle_summary"]["cue_count"], 1)
        self.assertEqual(prior, self.upload_files())

    async def test_alignment_upload_cancel_closes_input(self) -> None:
        upload = UploadFile(filename="sample.wav", file=io.BytesIO(b"temporary"))
        with (
            patch.object(service, "forced_aligner_status", return_value={"ready": True}),
            patch.object(service, "_save_upload", side_effect=asyncio.CancelledError()),
        ):
            with self.assertRaises(asyncio.CancelledError):
                await service.align_audio(
                    file=upload, transcript="hello", language="zh", preset="voiceover"
                )
        self.assertTrue(upload.file.closed)

    async def test_cancelled_alignment_keeps_normalized_audio_until_job_ends(self) -> None:
        started = threading.Event()
        finish = threading.Event()
        prior = self.upload_files()
        normalized = self.staged_file()
        upload = UploadFile(filename="sample.wav", file=io.BytesIO(b"fake wav"))
        alignment_result = {
            "items": [{"text": "hello", "start": 0.0, "end": 1.0}],
            "aligned_units": 1, "audio_duration_seconds": 1.0,
        }

        def fake_aligner(**_kwargs):
            started.set()
            if not finish.wait(5):
                raise TimeoutError("Synthetic alignment was not released")
            return alignment_result

        try:
            with (
                patch.object(service, "forced_aligner_status", return_value={"ready": True}),
                patch.object(service.ENGINE, "transcribe", return_value={"text": "hello"}),
                patch.object(service.ENGINE, "normalize_media", return_value=(normalized, normalized)),
                patch.object(service, "run_forced_alignment", side_effect=fake_aligner),
                patch.object(service, "segment_aligned_transcript", return_value=[{"text": "hello", "start": 0.0, "end": 1.0}]),
                patch.object(service, "summarize_cues", return_value={"cue_count": 1}),
                patch.object(service, "format_srt", return_value="test subtitle"),
            ):
                caller = asyncio.create_task(
                    service.align_audio(file=upload, transcript="hello", language="zh", preset="voiceover")
                )
                await self.until(started.is_set)
                caller.cancel()
                with self.assertRaises(asyncio.CancelledError):
                    await caller
                self.assertEqual(service.RUNNING, 1)
                self.assertTrue(normalized.exists())
                finish.set()
                await self.until(
                    lambda: service.RUNNING == 0 and not normalized.exists() and self.upload_files() == prior
                )
        finally:
            finish.set()

    async def test_declared_oversize_rejected_before_form_parsing(self) -> None:
        with patch.dict(service.CONFIG, {"max_upload_bytes": 10}):
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=service.APP), base_url="http://test"
            ) as client:
                response = await client.post(
                    "/v1/audio/transcriptions",
                    content=b"tiny",
                    headers={"Content-Length": str(1024 * 1024 + 100)},
                )
        self.assertEqual(response.status_code, 413)


if __name__ == "__main__":
    unittest.main()
