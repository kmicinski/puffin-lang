# Dockerfile for P1, CIS531
FROM --platform=linux/amd64 ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential clang gdb make curl ca-certificates \
    racket \
 && rm -rf /var/lib/apt/lists/*

# add common packages; extend as needed
#RUN raco pkg install --auto 

WORKDIR /work
