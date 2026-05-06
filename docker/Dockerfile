FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ffmpeg \
    libimage-exiftool-perl \
    gpac \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*
