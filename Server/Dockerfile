# syntax=docker/dockerfile:1
ARG BUN_IMAGE=oven/bun:1.4.2
ARG UBUNTU_IMAGE=ubuntu:24.04
ARG CUDA_IMAGE=nvidia/cuda:13.0.2-devel-ubuntu24.04

FROM ${BUN_IMAGE} AS bun-toolchain
FROM ${UBUNTU_IMAGE} AS sources
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential cmake curl ca-certificates git pkg-config libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*
COPY --from=bun-toolchain /usr/local/bin/bun /usr/local/bin/bun
WORKDIR /src
COPY Package.swift Package.resolved CMakeLists.txt THIRD_PARTY_NOTICES.md ./
COPY package.json bun.lock ./
COPY Sources ./Sources
COPY Tests ./Tests
COPY Engine ./Engine
COPY TextEngine ./TextEngine
COPY vendor ./vendor
COPY Resources ./Resources
COPY scripts ./scripts
COPY Server ./Server
ENV V07_NATIVE=OFF
ARG BUILD_JOBS=4
ENV V07_BUILD_JOBS=${BUILD_JOBS}

FROM sources AS cpu-build
RUN V07_CUDA=OFF ./scripts/build-server.sh

FROM ${CUDA_IMAGE} AS cuda-toolkit
FROM sources AS cuda-build
COPY --from=cuda-toolkit /usr/local/cuda-13.0/ /usr/local/cuda/
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64
# Override for the target GPU. Both 12.x Blackwell and older GPUs need a
# matching CUDA toolkit/driver; never infer architectures from the build host.
ARG CUDA_ARCHITECTURES=80;86;89;90;120;121
RUN V07_CUDA=ON V07_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" ./scripts/build-server.sh

FROM ${UBUNTU_IMAGE} AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 v07 \
    && mkdir -p /data /models && chown v07:v07 /data
ENV V07_SERVER_HOST=0.0.0.0 V07_SERVER_PORT=8391 V07_SERVER_DATA_DIR=/data
ENV V07_ENGINE_PATH=/opt/v07/helpers/v07-engine
ENV V07_TEXT_ENGINE_PATH=/opt/v07/helpers/v07-text-engine
ENV V07_VAD_PATH=/opt/v07/resources/silero-vad.bin
ENV V07_SPEECH_MODEL=/models/ggml-parakeet-tdt-0.6b-v3-f16.bin
ENV V07_TEXT_MODEL=/models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf
ENV V07_SERVER_TOKEN_FILE=/run/secrets/v07-token
USER v07
WORKDIR /opt/v07
EXPOSE 8391
HEALTHCHECK --interval=30s --timeout=3s --start-period=120s \
    CMD curl --fail --silent http://127.0.0.1:8391/v1/health > /dev/null || exit 1
ENTRYPOINT ["/opt/v07/v07-server"]

FROM runtime AS cuda
COPY --from=cuda-build /src/build/server/ /opt/v07/
COPY --from=cuda-toolkit /usr/local/cuda-13.0/ /usr/local/cuda/
ENV LD_LIBRARY_PATH=/usr/local/cuda/lib64
ENV NVIDIA_VISIBLE_DEVICES=all NVIDIA_DRIVER_CAPABILITIES=compute,utility

# CPU is the default target, useful for a portable build/smoke check. Use the
# cuda target for a GPU server and install NVIDIA Container Toolkit on its host.
FROM runtime AS cpu
COPY --from=cpu-build /src/build/server/ /opt/v07/
