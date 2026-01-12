# AI Context for spainify

This file is **AI-focused project context** intended to speed up future conversations and changes without re-explaining the system. It is not user-facing documentation.

## Purpose & Scope
- A Raspberry Pi-based display system that shows **now-playing music** or a **weather dashboard** on a dedicated screen.
- Music playback **always overrides** the weather display.
- Outside the weather window (7–9am local), the screen stays **off** unless music is playing in the **Living Room** Sonos group.

## High-Level Architecture
- `apps/spotify-display` (Python): screen controller + Chromium launcher.
- `apps/sonify` (Vue): now-playing UI.
- `apps/weather-dashboard` (React): weather UI.
- `apps/add-current` (Node): Spotify “add current track” microservice.
- `apps/sonos-http-api` (Node): Sonos control API (fork of `node-sonos-http-api`).
- `systemd/`: service units for all runtime processes.

## Key URLs / Ports
- Sonify UI: `http://localhost:5000`
- Weather dashboard: `http://localhost:3000`
- Sonos HTTP API: `http://localhost:5005`
- Add-current microservice: `http://localhost:3030`

## Display Behavior Rules (Authoritative)
- **7–9am local:** show weather dashboard **unless** music plays in Living Room group.
- **Outside 7–9am:** display is **off** unless music plays in Living Room group.
- Music playback detection only matters if **Living Room is in the active group** (ignore other rooms).
- Sonos playback covers Spotify Connect, Sonos app playback, and other music sources (e.g., iBroadcast).

## Playback Metadata Source
- Track title, artist, and artwork come from the **Sonos API**, not direct Spotify calls.
- Rationale: avoids Spotify auth/token refresh in the display path and works for non-Spotify sources (e.g., iBroadcast, Sonos app sources) with a single metadata flow.
- Known limitation: **only first artist** shown when multiple artists are present.

## Add-Current Microservice
- Endpoint: `GET /add-current-smart`
- Logic:
  - Try Spotify “currently playing” first.
  - If nothing is playing on Spotify, fall back to Sonos (music-only).
- De-dupe: window size is configurable via `DE_DUPE_WINDOW` in `apps/add-current/.env` (overrides default).

## iOS Shortcuts Usage
- A shortcut calls “add current track” to save songs to a playlist if not present.
- Additional shortcuts use `node-sonos-http-api` presets for full Sonos control:
  - Group or ungroup rooms
  - Set volume across rooms or groups
  - One-button macro: set volume, group rooms, clear queue, start a specified favorite
  - Play/pause

## Known UI Edge Cases
- **Long artist/track/album strings** can overflow the fixed display layout.
- Future fixes: dynamic text sizing or ellipsis handling.

## Operational Notes
- Minimal failure handling; issues are usually diagnosed manually when noticed.
- System is stable in practice; prioritize behavior rules above when making changes.

## Secrets & Safety
- `.env` files contain secrets and must **never** be committed.
- Use `.env.example` files as templates only.
