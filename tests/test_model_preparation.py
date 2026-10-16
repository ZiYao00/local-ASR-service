"""Offline model validation tests: purely in-memory, no actual downloads or model file writes."""
from __future__ import annotations

import importlib.util
import io
import json
import sys
import types
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "prepare-models.py"
SPEC = importlib.util.spec_from_file_location("model_preparation_under_test", MODULE_PATH)
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class FakeFile:
    def __init__(self, data, claimed_size=None):
        self.data = data
        self.claimed_size = claimed_size

    def is_file(self):
        return self.data is not None

    def stat(self):
        if self.data is None:
            raise FileNotFoundError("missing model fixture")
        return SimpleNamespace(st_size=self.claimed_size if self.claimed_size is not None else len(self.data))

    def open(self, mode="rb", encoding=None):
        if self.data is None:
            raise FileNotFoundError("missing model fixture")
        if "b" in mode:
            return io.BytesIO(self.data)
        return io.StringIO(self.data.decode("utf-8"))

    def read_text(self, encoding="utf-8"):
        if self.data is None:
            raise FileNotFoundError("missing model fixture")
        return self.data.decode(encoding)


class FakeDirectory:
    def __init__(self, entries, label="in-memory-snapshot"):
        self.entries = dict(entries)
        self.label = label

    def __truediv__(self, name):
        return self.entries.get(name, FakeFile(None))

    def __str__(self):
        return self.label


class FakeCacheDirectory:
    def mkdir(self, parents=False, exist_ok=False):
        # No filesystem operation.
        return None

    def __str__(self):
        return "memory-cache"


class FakeRoot:
    def __init__(self, refs=None):
        refs = refs or ("iic/model-one", "iic/model-two", "iic/model-three")
        config = {
            "modelPath": refs[0],
            "vadModel": refs[1],
            "puncModel": refs[2],
            "modelScopeCache": "virtual-cache",
        }
        self.settings = FakeFile(json.dumps(config).encode("utf-8"))
        self.cache = FakeCacheDirectory()

    def __truediv__(self, name):
        if name == "config/local.json":
            return self.settings
        if name == "virtual-cache":
            return self.cache
        return FakeDirectory({"model.pt": FakeFile(b"model fixture")})


def fake_base_sdk(downloader):
    """Replace the SDK import; never connect to an external service."""
    return patch.dict(sys.modules, {"modelscope": types.SimpleNamespace(snapshot_download=downloader)})


def make_weights(payload=b"fake tensor"):
    h = json.dumps({"weight": {"dtype": "U8", "shape": [len(payload)], "data_offsets": [0, len(payload)]}}).encode()
    return len(h).to_bytes(8, "little") + h + payload


def make_model():
    entries = {
        "config.json": FakeFile(b'{"model_type":"qwen3_asr"}'),
        "tokenizer_config.json": FakeFile(b"{}"),
        "vocab.json": FakeFile(b"{}"),
        "merges.txt": FakeFile(b"#version:0.2"),
        "preprocessor_config.json": FakeFile(b"{}"),
        "model.safetensors": FakeFile(make_weights()),
    }
    return FakeDirectory(entries)


class ModelPreparationTests(unittest.TestCase):
    def test_valid_safetensors_fixture(self):
        self.assertTrue(module.complete_qwen(make_model()))

    def test_truncated_tensor_payload(self):
        data = make_model()
        data.entries["model.safetensors"] = FakeFile(make_weights()[:-3])
        self.assertFalse(module.complete_qwen(data))

    def test_large_bogus_weight_is_not_accepted(self):
        data = make_model()
        # No large allocation: a fake stat reports 160 MB, but the content is invalid.
        data.entries["model.safetensors"] = FakeFile(b"not weights", claimed_size=160_000_000)
        self.assertFalse(module.complete_qwen(data))

    def test_invalid_tensor_header(self):
        data = make_model()
        data.entries["model.safetensors"] = FakeFile(b"12345678invalid")
        self.assertFalse(module.complete_qwen(data))

    def test_missing_support_file(self):
        for filename in ("vocab.json", "merges.txt", "preprocessor_config.json"):
            with self.subTest(filename=filename):
                data = make_model()
                del data.entries[filename]
                self.assertFalse(module.complete_qwen(data))

    def test_corrupted_config_json(self):
        data = make_model()
        data.entries["config.json"] = FakeFile(b"{malformed")
        self.assertFalse(module.complete_qwen(data))

    def test_existing_valid_cache_avoids_downloader(self):
        data = make_model()
        downloader = Mock(side_effect=AssertionError("download must not run"))
        stub = types.SimpleNamespace(snapshot_download=downloader)
        with patch.object(module, "QWEN_MODELS", {"aligner": ("example/model", data)}):
            with patch.dict(sys.modules, {"huggingface_hub": stub}):
                module.prepare_qwen("aligner", offline=False)
        downloader.assert_not_called()

    def test_offline_incomplete_cache_never_downloads(self):
        data = make_model()
        data.entries["model.safetensors"] = FakeFile(make_weights()[:-1])
        downloader = Mock(side_effect=AssertionError("download must not run"))
        stub = types.SimpleNamespace(snapshot_download=downloader)
        with patch.object(module, "QWEN_MODELS", {"aligner": ("example/model", data)}):
            with patch.dict(sys.modules, {"huggingface_hub": stub}):
                with self.assertRaisesRegex(RuntimeError, "not complete"):
                    module.prepare_qwen("aligner", offline=True)
        downloader.assert_not_called()

    def test_base_modelscope_offline_only_requests_cached_snapshots(self):
        downloader = Mock(return_value="fake-snapshot")
        folder = FakeDirectory({"model.pt": FakeFile(b"cached")})
        with (
            patch.object(module, "ROOT", FakeRoot()),
            patch.object(module, "Path", lambda path: folder),
            fake_base_sdk(downloader),
            patch.dict(module.os.environ, {}, clear=False),
        ):
            module.prepare_base(offline=True)
        self.assertEqual(downloader.call_count, 3)
        for call in downloader.call_args_list:
            self.assertTrue(call.kwargs["local_files_only"])

    def test_base_modelscope_cache_miss_uses_sdk_recovery(self):
        calls = []
        def downloader(model_id, cache_dir, local_files_only=False):
            calls.append((model_id, local_files_only))
            if model_id == "iic/model-one" and local_files_only:
                raise FileNotFoundError("simulated cache miss")
            return "fake-snapshot"
        folder = FakeDirectory({"model.pt": FakeFile(b"cached")})
        with (
            patch.object(module, "ROOT", FakeRoot()),
            patch.object(module, "Path", lambda path: folder),
            fake_base_sdk(downloader),
            patch.dict(module.os.environ, {}, clear=False),
        ):
            module.prepare_base(offline=False)
        self.assertEqual(len(calls), 4)
        self.assertEqual(calls[:2], [("iic/model-one", True), ("iic/model-one", False)])
        self.assertTrue(all(local for _, local in calls[2:]))

    def test_base_offline_cache_miss_never_attempts_download(self):
        downloader = Mock(side_effect=FileNotFoundError("simulated offline cache miss"))
        folder = FakeDirectory({"model.pt": FakeFile(b"cached")})
        with (
            patch.object(module, "ROOT", FakeRoot()),
            patch.object(module, "Path", lambda path: folder),
            fake_base_sdk(downloader),
            patch.dict(module.os.environ, {}, clear=False),
        ):
            with self.assertRaises(FileNotFoundError):
                module.prepare_base(offline=True)
        downloader.assert_called_once()
        self.assertTrue(downloader.call_args.kwargs["local_files_only"])

    def test_simulated_network_failure_then_resume(self):
        data = make_model()
        data.entries["model.safetensors"] = FakeFile(make_weights()[:-2])
        existing_config = data.entries["config.json"]
        downloader = Mock(side_effect=ConnectionError("simulated network interruption"))
        stub = types.SimpleNamespace(snapshot_download=downloader)
        with patch.object(module, "QWEN_MODELS", {"aligner": ("example/model", data)}):
            with patch.dict(sys.modules, {"huggingface_hub": stub}):
                with self.assertRaises(ConnectionError):
                    module.prepare_qwen("aligner", offline=False)
                self.assertFalse(module.complete_qwen(data))
                self.assertIs(existing_config, data.entries["config.json"])
                def resume(*args, **kwargs):
                    data.entries["model.safetensors"] = FakeFile(make_weights())
                downloader.side_effect = resume
                module.prepare_qwen("aligner", offline=False)
                self.assertTrue(module.complete_qwen(data))
                self.assertIs(existing_config, data.entries["config.json"])
        self.assertEqual(downloader.call_count, 2)

    def test_mock_downloader_partial_return_must_fail(self):
        data = make_model()
        data.entries["model.safetensors"] = FakeFile(make_weights()[:-4])
        downloader = Mock(return_value=None)
        stub = types.SimpleNamespace(snapshot_download=downloader)
        with patch.object(module, "QWEN_MODELS", {"aligner": ("example/model", data)}):
            with patch.dict(sys.modules, {"huggingface_hub": stub}):
                with self.assertRaisesRegex(RuntimeError, "incomplete"):
                    module.prepare_qwen("aligner", offline=False)
        downloader.assert_called_once()


if __name__ == "__main__":
    unittest.main()
