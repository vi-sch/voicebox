"""Small compatibility helpers for PyTorch-dependent third-party packages."""

from __future__ import annotations

import logging
from typing import Any

logger = logging.getLogger(__name__)


class _UnavailableXPU:
    """Minimal ``torch.xpu`` stand-in for Torch builds without Intel XPU."""

    @staticmethod
    def is_available() -> bool:
        return False

    @staticmethod
    def device_count() -> int:
        return 0

    @staticmethod
    def empty_cache() -> None:
        return None

    @staticmethod
    def manual_seed(seed: int) -> None:
        return None


def ensure_torch_xpu_compat(torch_module: Any) -> bool:
    """Provide ``torch.xpu`` when a dependency assumes the attribute exists.

    Some Torch builds, notably older ROCm/CPU wheels, do not expose
    ``torch.xpu``. Newer diffusers releases reference ``torch.xpu.empty_cache``
    during module import, which can break Chatterbox before Voicebox chooses a
    device. Installing an unavailable no-op XPU namespace keeps that import
    compatible without changing device selection.

    Returns:
        True when a compatibility namespace was installed.
    """
    if hasattr(torch_module, "xpu"):
        return False

    torch_module.xpu = _UnavailableXPU()
    logger.debug("Installed torch.xpu compatibility namespace")
    return True
