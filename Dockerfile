# Studio pod image: plain ComfyUI (torch cu128), no SwarmUI.
# Built by GitHub Actions, served from GHCR, runs on any RunPod GPU (4090..B200).
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl wget ca-certificates python3 python3-venv python3-pip gcc python3-dev \
      openssh-server unzip ffmpeg cmake g++ make libgl1 libglib2.0-0 libxcb1 libsm6 libxext6 libxrender1 \
      libegl1 libglvnd0 libgles2 && \
    rm -rf /var/lib/apt/lists/*
# rclone + tailscale baked in (no boot-time installs)
RUN curl -fsSL https://rclone.org/install.sh | bash && \
    curl -fsSL https://tailscale.com/install.sh | sh
# ComfyUI at a PINNED release. To upgrade: change COMFY_REF and push -> this layer and
# everything below rebuilds (the old setup froze ComfyUI at the first build via the cache).
# torch pinned to cu128 (Blackwell-ready); extra packages packs import without declaring
# (mediapipe: comfyui_facetools imports it but declares NO deps anywhere - found the hard way)
ARG COMFY_REF=v0.38.2
RUN git clone --depth 1 --branch "${COMFY_REF}" https://github.com/comfyanonymous/ComfyUI.git /comfy && \
    python3 -m venv /comfy/venv && \
    /comfy/venv/bin/pip install --no-cache-dir --upgrade pip && \
    /comfy/venv/bin/pip install --no-cache-dir \
        torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128 && \
    /comfy/venv/bin/pip install --no-cache-dir -r /comfy/requirements.txt && \
    /comfy/venv/bin/pip install --no-cache-dir \
        rembg onnxruntime matplotlib opencv-python-headless imageio-ffmpeg dill omegaconf diffusers ultralytics \
        mediapipe && \
    { /comfy/venv/bin/pip cache purge || true; } && \
    rm -rf /comfy/.git /root/.cache/pip && \
    mv /comfy/models /comfy/models.dist
# Custom ComfyUI nodes from nodes.txt, cloned at pinned commits and their pip
# requirements installed at build time (zero boot-time cost; build fails loudly
# if a node or its deps are broken)
COPY nodes.txt /studio/nodes.txt
RUN COMFY_DIR=/comfy && \
    cd "$COMFY_DIR/custom_nodes" && \
    while IFS= read -r spec || [ -n "$spec" ]; do \
      case "$spec" in ""|"#"*) continue;; esac; \
      url="${spec%@*}"; ref="${spec##*@}"; name="$(basename "$url" .git)"; \
      echo "== installing node: $name"; \
      git clone --quiet "$url" "$name" || exit 1; \
      if [ "$ref" != "$spec" ]; then git -C "$name" checkout --quiet "$ref" || exit 1; fi; \
      if [ -f "$name/requirements.txt" ]; then \
        sed -i -e '\#git+https://github.com/facebookresearch/sam2#d' -e '/^decord/d' "$name/requirements.txt"; \
        "$COMFY_DIR/venv/bin/pip" install --no-cache-dir -r "$name/requirements.txt" || exit 1; fi; \
      rm -rf "$name/.git"; \
    done < /studio/nodes.txt && \
    echo "== custom_nodes now: $(ls "$COMFY_DIR/custom_nodes")" && \
    { "$COMFY_DIR/venv/bin/pip" cache purge || true; } && \
    rm -rf /root/.cache/pip
# QwenVL FP8 on CUDA<13 needs these exact pins (workflow author's verified set) -
# installed LAST so no pack requirement can re-upgrade them; xformers out per same guide.
RUN "/comfy/venv/bin/pip" install --no-cache-dir --force-reinstall --no-deps \
        "huggingface_hub==1.7.1" "transformers==5.3.0" "tokenizers==0.22.2" && \
    { "/comfy/venv/bin/pip" uninstall -y xformers 2>/dev/null || true; }
COPY boot.sh /studio/boot.sh
RUN chmod +x /studio/boot.sh
EXPOSE 22 8188
ENTRYPOINT ["/bin/bash", "/studio/boot.sh"]