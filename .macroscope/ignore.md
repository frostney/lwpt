---
ignoreTests: false
---

## Tool-managed state

.agents/skills/**
.claude/skills/**
skills-lock.json

## Build and generated output

build/**
source/Version.inc
tests/test-inventory.tsv
lwpt.cfg

## Installed dependencies and verification archives

.lwpt/modules/**
.lwpt/archives/**

## Archives

**/*.zip
**/*.tar
**/*.gz
**/*.7z
**/*.bz2

## Compiled and binary artifacts

**/*.exe
**/*.dll
**/*.so
**/*.dylib
**/*.bin
**/*.o
**/*.a
**/*.ppu
**/*.rsj
**/*.compiled
**/*.wasm
**/*.p12
**/*.pem

## Machine-written lock files

lwpt.lock
**/*.lock

## Non-reviewable media

**/*.jpg
**/*.jpeg
**/*.png
**/*.gif
**/*.svg
**/*.ico
**/*.webp
**/*.bmp
**/*.tiff
**/*.woff
**/*.woff2
**/*.ttf
**/*.eot
**/*.otf
**/*.mp3
**/*.mp4
**/*.wav
**/*.avi
**/*.mov
**/*.mkv
**/*.flac
**/*.ogg
**/*.srt
