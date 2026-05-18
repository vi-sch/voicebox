"""Helpers for classifying GPU backends across startup and health checks."""

from typing import Any


def is_rocm_torch(torch_module: Any) -> bool:
    """Return True when the loaded torch build is backed by ROCm/HIP."""
    version = getattr(torch_module, "version", None)
    return getattr(version, "hip", None) is not None


def format_torch_cuda_gpu_type(torch_module: Any, device_name: str) -> str:
    """Format a torch.cuda device name as CUDA or ROCm."""
    backend_name = "ROCm" if is_rocm_torch(torch_module) else "CUDA"
    return f"{backend_name} ({device_name})"


def detect_backend_variant(torch_module: Any, *, has_xpu: bool = False) -> str:
    """Return the backend variant string exposed by the health endpoint."""
    if hasattr(torch_module, "cuda") and torch_module.cuda.is_available():
        return "rocm" if is_rocm_torch(torch_module) else "cuda"
    if has_xpu:
        return "xpu"
    return "cpu"
