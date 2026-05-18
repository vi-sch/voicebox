from types import SimpleNamespace

from backend.utils.gpu import detect_backend_variant, format_torch_cuda_gpu_type, is_rocm_torch


class _FakeCuda:
    def __init__(self, available: bool):
        self._available = available

    def is_available(self) -> bool:
        return self._available


def _fake_torch(*, cuda_available: bool, hip_version: str | None = None) -> SimpleNamespace:
    return SimpleNamespace(
        cuda=_FakeCuda(cuda_available),
        version=SimpleNamespace(hip=hip_version),
    )


def test_is_rocm_torch_detects_hip_build():
    assert is_rocm_torch(_fake_torch(cuda_available=True, hip_version="6.3.0")) is True
    assert is_rocm_torch(_fake_torch(cuda_available=True, hip_version=None)) is False


def test_format_torch_cuda_gpu_type_uses_rocm_label_for_hip_build():
    torch_module = _fake_torch(cuda_available=True, hip_version="6.3.0")
    assert format_torch_cuda_gpu_type(torch_module, "AMD Radeon RX 7900 XTX") == "ROCm (AMD Radeon RX 7900 XTX)"


def test_detect_backend_variant_distinguishes_rocm_cuda_xpu_and_cpu():
    assert detect_backend_variant(_fake_torch(cuda_available=True, hip_version="6.3.0")) == "rocm"
    assert detect_backend_variant(_fake_torch(cuda_available=True, hip_version=None)) == "cuda"
    assert detect_backend_variant(_fake_torch(cuda_available=False), has_xpu=True) == "xpu"
    assert detect_backend_variant(_fake_torch(cuda_available=False), has_xpu=False) == "cpu"
