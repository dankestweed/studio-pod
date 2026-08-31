# Studio pod image: SwarmUI + ComfyUI (torch cu128) + dotnet, pre-configured.
# Built by GitHub Actions, served from GHCR, runs on any RunPod GPU (4090..B200).
FROM nvidia/cuda:12.8.0-runtime-ubuntu24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git curl ca-certificates python3 python3-venv python3-pip \
      openssh-server unzip && \
    rm -rf /var/lib/apt/lists/*

# rclone + tailscale baked in (no boot-time installs)
RUN curl -fsSL https://rclone.org/install.sh | bash && \
    curl -fsSL https://tailscale.com/install.sh | sh

# SwarmUI, built ahead of time
WORKDIR /SwarmUI
RUN git clone --depth 1 https://github.com/mcmonkeyprojects/SwarmUI.git . && \
    bash launchtools/linux-dotnet-install.sh /SwarmUI/.dotnet && \
    export PATH="/SwarmUI/.dotnet:$PATH" && \
    bash launchtools/linux-build-logic.sh && \
    test -e src/bin/live_release

# ComfyUI via SwarmUI's own installer, then pin torch to cu128 (Blackwell-ready)
RUN export PATH="/SwarmUI/.dotnet:$PATH" && \
    bash launchtools/comfy-install-linux.sh nv && \
    COMFY_DIR=$(dirname $(find /SwarmUI/dlbackend -name main.py -path '*ComfyUI*' | head -1)) && \
    "$COMFY_DIR/venv/bin/pip" install --no-cache-dir --force-reinstall \
        torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128 && \
    "$COMFY_DIR/venv/bin/pip" cache purge || true && \
    rm -rf "$COMFY_DIR/.git" /root/.cache/pip

COPY boot.sh /studio/boot.sh
RUN chmod +x /studio/boot.sh
EXPOSE 22 7801
ENTRYPOINT ["/bin/bash", "/studio/boot.sh"]
