from types import SimpleNamespace

from backend.utils.torch_compat import ensure_torch_xpu_compat


def test_ensure_torch_xpu_compat_installs_unavailable_namespace():
    torch_module = SimpleNamespace()

    assert ensure_torch_xpu_compat(torch_module) is True
    assert torch_module.xpu.is_available() is False
    assert torch_module.xpu.device_count() == 0
    assert torch_module.xpu.empty_cache() is None
    assert torch_module.xpu.manual_seed(123) is None

    cache_hooks = {"xpu": torch_module.xpu.empty_cache}
    assert cache_hooks["xpu"]() is None


def test_ensure_torch_xpu_compat_preserves_existing_namespace():
    existing_xpu = SimpleNamespace(is_available=lambda: True)
    torch_module = SimpleNamespace(xpu=existing_xpu)

    assert ensure_torch_xpu_compat(torch_module) is False
    assert torch_module.xpu is existing_xpu
