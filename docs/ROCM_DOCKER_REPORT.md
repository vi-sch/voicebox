# ROCm Docker Report

Date: 2026-04-24

## Scope

This report summarizes the ROCm and Docker findings for running Voicebox on the host's AMD GPU and exposing the web UI over ZeroTier.

## Hardware

- Host OS: Ubuntu 24.04.3 LTS
- Kernel: `6.18.2-1-t2-noble`
- GPU: AMD Vega 20 / Radeon Pro Vega II class
- ROCm GPU target reported by `rocminfo`: `gfx906`
- Reported VRAM from `rocminfo`: about 32 GiB
- ZeroTier interface: `ztw4lpboi7`
- ZeroTier host IP used for Voicebox: `10.144.69.220`

## Host ROCm State

The host currently has a mixed ROCm installation:

- ROCm 7.0.2 packages are installed and `/opt/rocm` points to `/opt/rocm-7.0.2`.
- ROCm 6.3.3 packages are also installed side by side under `/opt/rocm-6.3.3`.
- `amdgpu-dkms` is not installed.
- The active AMD kernel driver is the in-tree kernel `amdgpu` module.
- `/dev/kfd`, `/dev/dri/renderD128`, and `/dev/dri/card1` exist on the host.
- `/dev/kfd` and `/dev/dri/renderD128` are owned by group `render`.
- `/dev/dri/card1` is owned by group `video`.
- The host user is a member of both `video` and `render`.

This is sufficient for Docker passthrough because the container mainly needs the host kernel driver and the device nodes. The ROCm userspace libraries can live inside the container.

## Host Runtime Tests

### ROCm 7.0.2

Result: partial pass.

- `/opt/rocm-7.0.2/bin/rocminfo` successfully enumerated the `gfx906` GPU.
- The installed ROCm 7.0.2 stack did not include the HIP compiler/dev headers in the same way as 6.3.3.
- A forced mixed-runtime HIP test using a 6.3.3-built binary with 7.0.2 runtime libraries failed with `no ROCm-capable device is detected`.

Conclusion: ROCm 7.0.2 can see the GPU through HSA, but this host installation is not a proven working PyTorch/HIP runtime path for Voicebox.

### ROCm 6.3.3

Result: pass for native HIP kernel execution.

- `/opt/rocm-6.3.3/bin/rocminfo` successfully enumerated the `gfx906` GPU.
- `hipcc --version` reported HIP `6.3.42134`.
- A small HIP smoke test compiled with `--offload-arch=gfx906` ran successfully.
- The HIP smoke test detected one AMD GPU, reported `gcn_arch=gfx906:sramecc-:xnack-`, allocated GPU memory, launched a kernel, synchronized, copied results back, and returned `kernel_result=ok`.

Conclusion: ROCm 6.3.3 works for direct native HIP kernel execution on this host.

## Docker Runtime Tests

### ROCm 6.3 PyTorch Image

Image tested:

```text
rocm/pytorch:rocm6.3_ubuntu24.04_py3.12_pytorch_release_2.4.0
```

Result: fail for PyTorch GPU execution.

The container saw the GPU:

```text
available True
name AMD Radeon Graphics
```

But the first simple PyTorch GPU tensor operation failed:

```text
RuntimeError: HIP error: invalid device function
```

Conclusion: do not use ROCm 6.3 PyTorch for this `gfx906` GPU in Docker. Enumeration is not enough; PyTorch kernel execution fails.

### ROCm 5.7 PyTorch Image

Image attempted:

```text
rocm/pytorch:rocm5.7_ubuntu22.04_py3.10_pytorch_2.0.1
```

Result: not completed.

The pull was stopped because the AMD `rocm/pytorch` image class is very large. The image was not validated end to end.

Conclusion: ROCm 5.7 remains the recommended compatibility target for `gfx906`, but avoid AMD's full `rocm/pytorch` image if disk usage matters.

## Docker Image Size Findings

The AMD ROCm PyTorch images are very large because they bundle a full ML development/runtime stack:

- ROCm runtime libraries
- HIP/HSA components
- LLVM/compiler tooling
- PyTorch
- math libraries such as rocBLAS/MIOpen
- many precompiled GPU kernel assets
- Ubuntu/Python base layers

Observed local sizes before cleanup:

```text
rocm/pytorch:rocm6.3...   95.7GB
voicebox-voicebox         11.1GB
Docker build cache        99.8GB
```

Cleanup performed:

- Removed `voicebox-voicebox:latest`.
- Removed `rocm/pytorch:rocm6.3_ubuntu24.04_py3.12_pytorch_release_2.4.0`.
- Pruned Docker build cache, reclaiming 111.7GB.
- Preserved Docker volumes.

Final checked Docker state after cleanup:

```text
Images: hello-world only
Build Cache: 0B
Volumes: preserved
```

## Current Docker Compose Approach

The compose setup was changed to avoid AMD's full ROCm PyTorch image.

Current strategy:

- Base image: `python:3.10-slim-bookworm`
- PyTorch install: official PyTorch ROCm 5.7 wheels
- PyTorch wheel index: `https://download.pytorch.org/whl/rocm5.7`
- PyTorch version: `2.2.2`
- TorchVision version: `0.17.2`
- Torchaudio version: `2.2.2`
- Runtime target: `runtime-rocm`
- GPU override: `HSA_OVERRIDE_GFX_VERSION=9.0.6`
- Additional runtime package: `libatomic1`, required by `pedalboard_native`
- HuggingFace transfer override: `HF_HUB_DISABLE_XET=1`

Important compose settings:

```yaml
devices:
  - /dev/kfd:/dev/kfd
  - /dev/dri:/dev/dri

group_add:
  - "${HOST_VIDEO_GID:-44}"
  - "${HOST_RENDER_GID:-991}"

ipc: host
shm_size: 8gb

security_opt:
  - seccomp:unconfined
```

The web UI is bound to the host ZeroTier IP and the Ethernet LAN IP:

```text
http://10.144.69.220:17493
http://192.168.1.2:17493
```

## Recommendation

Stay on ROCm 5.7 for the container-side PyTorch stack.

Do not switch to ROCm 6.3 PyTorch even though the host ROCm 6.3.3 HIP compiler can run a native kernel. The actual PyTorch ROCm 6.3 container test failed with `invalid device function`, which is the relevant failure mode for Voicebox.

Use the slim Python base plus PyTorch ROCm 5.7 wheels instead of `rocm/pytorch:*`. This should be substantially smaller than AMD's full development image, but it will still be multi-GB because PyTorch ROCm and Voicebox's TTS dependencies are inherently large.

## Validation Result

The slim ROCm 5.7 Docker image initially reached application startup but failed while importing
`pedalboard_native`:

```text
ImportError: libatomic.so.1: cannot open shared object file: No such file or directory
```

The runtime image now installs Debian's `libatomic1` package and runs a build-time
`import pedalboard` smoke check so this failure is caught during image build.

Validation run on 2026-04-24:

```bash
docker compose -f docker-compose.yml -f docker-compose.rocm.yml up -d --build voicebox
```

Startup result:

```text
STATUS: healthy
GPU: ROCm (AMD Radeon Graphics)
Model cache: /home/voicebox/.cache/huggingface/hub
```

The container now starts cleanly, the HuggingFace cache directory is writable by the non-root
`voicebox` user, and `/health` reports `backend_variant: "rocm"`.

Real model load/generation validation:

```text
Model: Qwen CustomVoice 0.6B
Voice: Ryan
Status: completed
Generated audio duration: 3.28s
Audio probe: RIFF/WAVE header returned from /audio/{generation_id}
Health after generation: gpu_type="ROCm (AMD Radeon Graphics)", backend_variant="rocm", vram_used_mb≈2054
```

Notes from validation:

- The first model download attempt stalled in HuggingFace's Xet transfer helper, leaving the
  safetensors blob at 0 bytes. Setting `HF_HUB_DISABLE_XET=1` switched the download path to
  regular HTTP range transfers, after which the model downloaded successfully.
- The first completed inference attempt failed only when saving the WAV because the host `output/`
  bind mount was not writable by the non-root container user. The host `output/` directory was
  made writable and the rerun completed.
- The production web UI now defaults its API URL to the page origin and repairs stale persisted
  loopback URLs. This prevents remote browsers from loading the SPA over `192.168.1.2` while
  trying to fetch `/profiles` from the browser machine's own `localhost`.
- No `invalid device function` occurred during model load or generation.

## References

- AMD ROCm Docker documentation: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/how-to/docker.html
- PyTorch previous versions and ROCm wheel indexes: https://pytorch.org/get-started/previous-versions/
- AMD ROCm documentation: https://rocm.docs.amd.com/
