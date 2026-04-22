# Firefox Fixes — kenny-VivoBook (Ubuntu 26.04 / Snap)

## What this fixes
- **Wayland native mode** — MOZ_ENABLE_WAYLAND=1 (no more XWayland fallback)
- **VA-API hardware decode** — H264/HEVC via AMD Radeon Vega 7 / Mesa 26
- **WebRender GPU compositing** — force-enabled for smooth scroll + tab rendering
- **Performance tuning** — network connections, 512MB memory cache, JIT
- **Telemetry disabled** — removes ~5 background connections on every launch

## Restore


## Verify hardware decode is working
Open Firefox → navigate to about:support
- WebRender: should show WebRender
- GPU #1: should show AMD Radeon
After playing a video: about:performance → check GPU process
