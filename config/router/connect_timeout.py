"""Deployment-level HTTP timeout policy for LiteLLM's OpenAI backends.

YAML keeps numeric request/stream budgets for the router. This hook runs after
deployment selection and supplies the HTTP client with a separate connect
budget, without changing the long read budget needed by llama-swap cold starts.
"""

import math
import os

import httpx
from litellm.integrations.custom_logger import CustomLogger


class ConnectTimeout(CustomLogger):
    def __init__(self):
        super().__init__()
        self.seconds = float(os.environ.get("HUB_CONNECT_TIMEOUT", "3"))
        if not math.isfinite(self.seconds) or self.seconds <= 0:
            raise ValueError("HUB_CONNECT_TIMEOUT must be a finite positive number")

    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        budget = kwargs.get("timeout", 900)
        if kwargs.get("stream") and kwargs.get("stream_timeout") is not None:
            budget = kwargs["stream_timeout"]
        if isinstance(budget, httpx.Timeout):
            budget = httpx.Timeout(budget)
            budget.connect = self.seconds
        else:
            budget = httpx.Timeout(float(budget), connect=self.seconds)
        kwargs["timeout"] = budget
        return kwargs


timeout_policy = ConnectTimeout()
