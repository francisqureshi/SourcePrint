# SourcePrint

A silly solution to a silly problem.
A video post-production tool that composites consolidated graded segments back into blanked out source length original camera files (OCF) with frame-accurate timecode positioning.

## How It Works

1. Import your consolidated graded clips from a media managed grade project.
2. Import your OCF clips, or transcodes of them (ideally ProRes)
3. Link them in the linking page
4. Render:
  - The inital render makes a blank copy of the OCF file, with src TC burnt in as fast as possible, (also as small as possible as the file is 99% empty, its reasonalably small)
  - Then using Apple VideoToolBox / FFmpeg block level passthrough file maninuplation, SourcePrint "merges" the graded clips with the blanked file, almost instantly.

5. Relink in your NLE to these files avoid major conform hell :)



Layered composition with frame ownership analysis:

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3 (VFX)        │                     ▓▓▓▓▓▓               │
│ Layer 2 (Grades)     │       ███████████           ███████████  │
│ Layer 1 (Rush)       │ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │
├──────────────────────┼──────────────────────────────────────────┤
│ Final Output         │ ░░░░░░████████████░░▓▓▓▓▓▓░░███████████  │
│                      │ ^Rush ^Grade        ^VFX    ^Grade       │
└─────────────────────────────────────────────────────────────────┘

Legend:
  ░░░  Blank rush (timecode burn-in)
  ███  Graded segments (from DaVinci timeline)
  ▓▓▓  VFX shots (absolute priority, never overwritten)
```

## Features

- **Timecode-Based Linking** - Matches graded segments to OCF using SMPTE timecode
- **Frame Ownership Analysis** - Resolves overlaps with VFX absolute priority
- **Blank Rush Generation** - Hardware-accelerated ProRes 4444 with timecode burn-in
- **Professional Standards** - All broadcast frame rates (23.976-120fps, drop/non-drop)

## Download via Releases^

## Build

```bash
# Build static FFmpeg + dependencies (one-time setup)
./build-static-deps.sh
./build-static-ffmpeg.sh

# Build SourcePrint.app
./build-sourceprint.sh
```

## Technical Stack

- **Swift** - Core engine and SwiftUI interface
- **SwiftFFmpeg** - Video processing with static FFmpeg 7.1.2
- **TimecodeKit** - SMPTE timecode calculations
- **VideoToolbox** - Hardware-accelerated ProRes encoding

* Note: The swift code in this project is 95% vibe coded - this project is my attempt at learning how video processing / ffmpeg / swift / macos apps work, with a focus of hand re-writing the backend in Zig and possibly removing or at least reducing the ffmpeg dependancy in favour of learning how remuxing and encoding works... and hand rolling my own attempt! :)
