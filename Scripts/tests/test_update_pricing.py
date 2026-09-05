import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "update-pricing.py"
SPEC = importlib.util.spec_from_file_location("update_pricing", SCRIPT)
update_pricing = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(update_pricing)


class UpdatePricingTests(unittest.TestCase):
    def test_includes_current_and_future_numbered_gpt_families(self):
        for model in ["gpt-4o", "gpt-5.6-sol", "gpt-6-astra", "openai/gpt-6-astra", "gpt-7", "gpt-10"]:
            with self.subTest(model=model):
                self.assertTrue(update_pricing.is_relevant(model, {"litellm_provider": "openai"}))

    def test_preserves_provider_and_model_category_boundaries(self):
        for model, provider in [
            ("gpt-6-astra", "azure"),
            ("gpt-6-astra", "unknown"),
            ("gpt-3.5-turbo", "openai"),
            ("gpt-image-2", "openai"),
            ("gpt-realtime-2", "openai"),
            ("text-embedding-3-large", "openai"),
        ]:
            with self.subTest(model=model, provider=provider):
                self.assertFalse(update_pricing.is_relevant(model, {"litellm_provider": provider}))

    def test_refresh_writes_astra_standard_and_cache_rates(self):
        payload = {
            "gpt-6-astra": {
                "litellm_provider": "openai",
                "input_cost_per_token": 0.00001,
                "output_cost_per_token": 0.00005,
                "cache_creation_input_token_cost": 0.0000125,
                "cache_read_input_token_cost": 0.000001,
            },
            "gpt-6-without-pricing": {"litellm_provider": "openai"},
        }
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "model_prices.json"
            response = io.BytesIO(json.dumps(payload).encode())
            with patch.object(update_pricing.urllib.request, "urlopen", return_value=response), \
                 patch.object(update_pricing, "DEST", destination), \
                 redirect_stderr(io.StringIO()):
                update_pricing.main()
            self.assertEqual(json.loads(destination.read_text()), {
                "gpt-6-astra": {
                    "inputPerMillion": 10,
                    "outputPerMillion": 50,
                    "cacheWritePerMillion": 12.5,
                    "cacheReadPerMillion": 1,
                }
            })


if __name__ == "__main__":
    unittest.main()
