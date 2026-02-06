// server.js
// Node 18+, ESM
import express from "express";
import fetch from "node-fetch";
import dotenv from "dotenv";
import { Buffer } from "node:buffer";
import { URLSearchParams } from "node:url";

dotenv.config();

const {
  SPOTIFY_CLIENT_ID,
  SPOTIFY_CLIENT_SECRET,
  SPOTIFY_REFRESH_TOKEN,
  SPOTIFY_PLAYLIST_ID,
  SONOS_HTTP_BASE = "http://127.0.0.1:5005",
  PREFERRED_ROOM = "",
  DE_DUPE_WINDOW = "250",
  PORT = 3030
} = process.env;

const app = express();

app.use(express.json());

const recentAdds = new Map(); // trackId -> timestamp
const RECENT_TTL_MS = 10 * 60 * 1000; // 10 minutes

function pruneRecentAdds(now = Date.now()) {
  const cutoff = now - RECENT_TTL_MS;
  for (const [trackId, ts] of recentAdds.entries()) {
    if (ts < cutoff) recentAdds.delete(trackId);
  }
}

function seenRecently(trackId) {
  const t = recentAdds.get(trackId);
  if (!t) return false;
  if ((Date.now() - t) >= RECENT_TTL_MS) {
    recentAdds.delete(trackId);
    return false;
  }
  return true;
}
function rememberAdd(trackId) {
  const now = Date.now();
  pruneRecentAdds(now);
  recentAdds.set(trackId, now);
}

/* ───────────────────────── Helpers ───────────────────────── */

function extractSpotifyTrackId(uri) {
  if (!uri) return null;
  const m1 = uri.match(/spotify%3atrack%3a([A-Za-z0-9]+)/); // encoded
  if (m1) return m1[1];
  const m2 = uri.match(/spotify:track:([A-Za-z0-9]+)/);     // plain
  if (m2) return m2[1];
  return null;
}

function isTvLikeUri(uri = "") {
  // Sonos TV inputs often look like x-sonos-htastream:… or have HDMI/SPDIF hints
  return uri.startsWith("x-sonos-htastream:") || uri.includes(":spdif") || uri.includes(":hdmi_arc");
}

function isLineInUri(uri = "") {
  // Line-in / AirPlay relay
  return uri.startsWith("x-sonos-auxin:") || uri.includes("x-rincon-stream:");
}

function isMusicLikeTrack(track = {}) {
  const uri = track.uri || "";
  if (!uri) return false;
  if (isTvLikeUri(uri) || isLineInUri(uri)) return false; // exclude TV/line-in
  if (typeof track.duration === "number" && track.duration > 0 && track.title) return true;
  return /x-sonos-spotify:|spotify:track:|x-sonos-http:|^https?:\/\//.test(uri);
}

async function getZones() {
  const r = await fetch(`${SONOS_HTTP_BASE}/zones`);
  if (!r.ok) throw new Error(`/zones failed: ${r.status}`);
  return r.json();
}

function isActive(zone) {
  return zone.members.some(m => ["PLAYING", "TRANSITIONING"].includes(m.state?.playbackState));
}

function coordinatorOf(zone) {
  return zone.members.find(m => m.coordinator) || zone.members[0];
}

function zoneHasSpotifyTrack(zone) {
  const track = coordinatorOf(zone)?.state?.currentTrack || {};
  return !!extractSpotifyTrackId(track.uri || "");
}

function zoneHasMusic(zone) {
  const track = coordinatorOf(zone)?.state?.currentTrack || {};
  return isMusicLikeTrack(track);
}

/**
 * Pick the best active zone:
 * 1) If a room is specified, return that active room (respecting mode filter)
 * 2) Prefer zones that have a Spotify track
 * 3) Else, any zone that looks like music (not TV/line-in)
 * 4) Else, any active zone (last resort)
 *
 * mode: "music" (default) ignores TV/line-in, "any" doesn’t filter.
 */
function pickActiveZone(zones, preferredRoom, mode = "music") {
  const active = zones.filter(isActive);
  if (!active.length) return null;

  const filterByMode = zs => mode === "any" ? zs : zs.filter(zoneHasMusic);

  // 1) Preferred room
  if (preferredRoom) {
    const candidates = active.filter(z => z.members.some(m => m.roomName === preferredRoom));
    const filtered = filterByMode(candidates);
    if (filtered.length) return filtered[0];
  }

  // 2) Any Spotify zone (after mode filter)
  const spotifyFirst = filterByMode(active).filter(zoneHasSpotifyTrack);
  if (spotifyFirst.length) return spotifyFirst[0];

  // 3) Any music-like zone
  const musicZones = filterByMode(active);
  if (musicZones.length) return musicZones[0];

  // 4) Fallback: any active zone
  return active[0];
}

async function getAccessToken() {
  if (!SPOTIFY_REFRESH_TOKEN) throw new Error("Missing SPOTIFY_REFRESH_TOKEN");
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    refresh_token: SPOTIFY_REFRESH_TOKEN
  });
  const basic = Buffer.from(`${SPOTIFY_CLIENT_ID}:${SPOTIFY_CLIENT_SECRET}`).toString("base64");
  const r = await fetch("https://accounts.spotify.com/api/token", {
    method: "POST",
    headers: { Authorization: `Basic ${basic}`, "Content-Type": "application/x-www-form-urlencoded" },
    body
  });
  if (!r.ok) {
    const t = await r.text();
    throw new Error(`Token refresh failed: ${r.status} ${t}`);
  }
  const j = await r.json();
  return j.access_token;
}

async function addTrackToPlaylist(trackId) {
  if (!SPOTIFY_PLAYLIST_ID) throw new Error("Missing SPOTIFY_PLAYLIST_ID");
  const token = await getAccessToken();
  const r = await fetch(`https://api.spotify.com/v1/playlists/${SPOTIFY_PLAYLIST_ID}/tracks`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ uris: [`spotify:track:${trackId}`] })
  });
  if (!r.ok) {
    const t = await r.text();
    throw new Error(`Add failed: ${r.status} ${t}`);
  }
}

// Simple JSON fetch with retry + timeout to handle transient Spotify glitches
async function fetchJsonWithRetry(url, opts = {}, retries = 3, timeoutMs = 4000) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    const ac = new AbortController();
    const id = setTimeout(() => ac.abort(), timeoutMs);
    try {
      const r = await fetch(url, { ...opts, signal: ac.signal });
      clearTimeout(id);
      if (!r.ok) {
        const t = await r.text().catch(() => "");
        throw new Error(`${r.status} ${t}`);
      }
      return await r.json();
    } catch (err) {
      clearTimeout(id);
      if (attempt === retries) throw err;
      await new Promise(res => setTimeout(res, 200 * Math.pow(2, attempt))); // 200ms, 400ms, 800ms
    }
  }
}

/** Read the last N items of the playlist (the most recent end) and see if trackId exists. */
async function playlistHasTrack(trackId) {
  const windowSize = Number(DE_DUPE_WINDOW || 250);
  const token = await getAccessToken();
  const base = `https://api.spotify.com/v1/playlists/${SPOTIFY_PLAYLIST_ID}/tracks`;
  const headers = { Authorization: `Bearer ${token}` };

  // 1) Get total
  const meta = await fetchJsonWithRetry(`${base}?limit=1`, { headers });
  const total = Number(meta.total || 0);

  // 2) Scan from the end (most recent first)
  let offset = Math.max(0, total - windowSize);
  const end = total;

  while (offset < end) {
    const limit = Math.min(100, end - offset);
    const url = `${base}?fields=items(track(id))&limit=${limit}&offset=${offset}`;
    const j = await fetchJsonWithRetry(url, { headers });
    for (const it of (j.items || [])) {
      const id = it?.track?.id;
      if (id && id === trackId) return true;
    }
    const got = (j.items || []).length;
    if (got === 0) break;
    offset += got;
  }
  return false;
}


/** Use Spotify API to get the currently playing track for this account. */
async function getSpotifyCurrentlyPlayingTrack() {
  const token = await getAccessToken();
  const r = await fetch("https://api.spotify.com/v1/me/player/currently-playing", {
    headers: { Authorization: `Bearer ${token}` }
  });

  if (r.status === 204) return null; // nothing playing
  if (!r.ok) throw new Error(`Currently-playing failed: ${r.status} ${await r.text()}`);

  const j = await r.json();
  if (j.currently_playing_type !== "track") return null; // ignore podcasts, etc.

  const id = j?.item?.id;
  if (!id) return null;

  const title = j?.item?.name || null;
  const artist = (j?.item?.artists?.[0]?.name) || null;

  return { trackId: id, title, artist };
}

/* ───────────────────────── Endpoints ───────────────────────── */

app.get("/health", (_req, res) => res.json({ ok: true }));

// Smart behavior: add currently playing song to indiepop vibez playlist - try Spotify first; if empty, fall back to Sonos (music-only)
app.get("/add-current-smart", async (req, res) => {
  try {
    // 1) Spotify currently playing
    let picked = await getSpotifyCurrentlyPlayingTrack();
    let source = "spotify";

    // 2) Fall back to Sonos if Spotify shows nothing
    let zone = null;
    if (!picked) {
      source = "sonos";
      const roomOverride = (req.query.room || "").toString();
      const mode = ((req.query.mode || "music").toString().toLowerCase() === "any") ? "any" : "music";
      const zones = await getZones();
      zone  = pickActiveZone(zones, roomOverride || PREFERRED_ROOM, mode);

      if (!zone) return res.json({ added: false, reason: "Nothing playing (Spotify and Sonos empty)" });

      const coordinator = coordinatorOf(zone);
      const track = coordinator?.state?.currentTrack || {};
      const uri = track?.uri || "";

      if (mode !== "any" && (!isMusicLikeTrack(track))) {
        return res.json({
          added: false,
          reason: "Active zone is TV/line-in; ignoring in music mode",
          zone: zone.members.map(m => m.roomName),
          source
        });
      }

      const idFromSonos = extractSpotifyTrackId(uri);
      if (!idFromSonos) {
        return res.json({
          added: false,
          reason: "Current item is not a Spotify track (or no URI)",
          zone: zone.members.map(m => m.roomName),
          source
        });
      }

      picked = {
        trackId: idFromSonos,
        title: track?.title || null,
        artist: track?.artist || null,
        zone: zone.members.map(m => m.roomName)
      };
    }

    // 3) De-dupe: recent fast-path
    if (typeof seenRecently === "function" && seenRecently(picked.trackId)) {
      return res.json({
        added: false,
        reason: "already in playlist (recent)",
        source,
        trackId: picked.trackId,
        title: picked.title || null,
        artist: picked.artist || null,
        zone: picked.zone || (zone ? zone.members.map(m => m.roomName) : null)
      });
    }

    // 3b) De-dupe against last N items
    if (await playlistHasTrack(picked.trackId)) {
      return res.json({
        added: false,
        reason: "already in playlist",
        source,
        trackId: picked.trackId,
        title: picked.title || null,
        artist: picked.artist || null,
        zone: picked.zone || (zone ? zone.members.map(m => m.roomName) : null)
      });
    }

    // 4) Add + remember
    await addTrackToPlaylist(picked.trackId);
    if (typeof rememberAdd === "function") rememberAdd(picked.trackId);

    return res.json({
      added: true,
      source,
      trackId: picked.trackId,
      title: picked.title || null,
      artist: picked.artist || null,
      zone: picked.zone || (zone ? zone.members.map(m => m.roomName) : null)
    });
  } catch (e) {
    res.status(500).json({ added: false, error: e.message });
  }
});


/* ─────────────── Grouping helpers & endpoint ─────────────── */

// Find the (possibly idle) zone that contains a given room
function zoneByRoom(zones, roomName = "") {
  if (!roomName) return null;
  return zones.find(z => z.members.some(m => m.roomName === roomName)) || null;
}


function encodeRoom(room = "") {
  return encodeURIComponent(room);
}

async function joinRoomTo(room, coordinatorRoom) {
  const url = `${SONOS_HTTP_BASE}/${encodeRoom(room)}/join/${encodeRoom(coordinatorRoom)}`;
  const r = await fetch(url);
  if (!r.ok) {
    const t = await r.text().catch(() => "");
    throw new Error(`join ${room} -> ${coordinatorRoom} failed: ${r.status} ${t}`);
  }
  return true;
}

// Helper to set a room's volume
async function setRoomVolume(room, vol) {
  const v = Math.max(0, Math.min(100, Number(vol)));
  if (Number.isNaN(v)) throw new Error(`invalid volume for ${room}: ${vol}`);
  const url = `${SONOS_HTTP_BASE}/${encodeRoom(room)}/volume/${v}`;
  const r = await fetch(url);
  if (!r.ok) {
    const t = await r.text().catch(() => "");
    throw new Error(`volume ${room} -> ${v} failed: ${r.status} ${t}`);
  }
  return true;
}

// Parse "volumes" from JSON body or query (?vol=Room:Level, repeated or CSV)
function parseVolumes(req) {
  const out = {};
  const raw = (req.body && req.body.volumes) ?? req.query.volumes ?? req.query.vol;
  const add = (s) => {
    for (const part of String(s).split(",")) {
      const [name, num] = part.split(":");
      if (name && num != null) out[name.trim()] = Number(num);
    }
  };
  if (!raw) return out;
  if (Array.isArray(raw)) raw.forEach(add); else add(raw);
  return out;
}

/**
 * GET or POST /group
 *  - GET  : /group?rooms=Kitchen&rooms=Bedroom&mode=music&vol=Kitchen:12&vol=Bedroom:18
 *  - POST : JSON { rooms:[...], mode:"music", volumes:{ "Kitchen":12, "Bedroom":18 } }
 */
app.all("/group", async (req, res) => {
  try {
    const method = req.method.toUpperCase();
    const mode = (String((req.body?.mode ?? req.query.mode ?? "music")).toLowerCase() === "any") ? "any" : "music";
    const preferred = String(req.body?.preferred ?? req.query.preferred ?? PREFERRED_ROOM ?? "");

    // Rooms (from JSON or query)
    let rooms = [];
    if (method === "POST" && Array.isArray(req.body?.rooms)) {
      rooms = req.body.rooms;
    } else {
      let q = req.query.rooms;
      if (Array.isArray(q)) rooms = q.flatMap(s => String(s).split(","));
      else if (typeof q === "string") rooms = String(q).split(",");
    }
    rooms = rooms.map(r => r.trim()).filter(Boolean);
    if (rooms.length === 0) {
      return res.status(400).json({ ok: false, error: "Provide rooms (JSON rooms[] or ?rooms=...)" });
    }

    const volumesMap = parseVolumes(req); // { "Living Room": 10, ... }

    // Get zones and TRY to pick an active coordinator (existing behavior)
    const zones = await getZones();
    let zone = pickActiveZone(zones, preferred, mode);

    // Resolve coordinator name with idle-safe fallback:
    //  - If there is an active zone, use its coordinator.
    //  - Otherwise, use preferred room if provided, else the first requested room.
    let coordinatorName = zone ? (coordinatorOf(zone)?.roomName) : "";
    if (!coordinatorName) {
      coordinatorName = preferred || rooms[0];
    }
    if (!coordinatorName) {
      return res.status(500).json({ ok: false, error: "Could not resolve coordinator name" });
    }

    // Determine existing membership from the zone that contains the coordinator,
    // even if the whole system is idle.
    const coordZone = zoneByRoom(zones, coordinatorName);
    const existing = new Set(
      coordZone ? coordZone.members.map(m => m.roomName) : [coordinatorName]
    );

    // Skip rooms already grouped (or the coordinator itself)
    const toJoin = rooms.filter(r => r && r !== coordinatorName && !existing.has(r));

    // Join rooms sequentially with a short delay to avoid stereo-pair race conditions
    const joined = [];
    const joinFailed = [];
    for (const room of toJoin) {
      try {
        await joinRoomTo(room, coordinatorName);
        joined.push(room);

        // Give Sonos ~200ms to settle before next join
        await new Promise(r => setTimeout(r, 200));
      } catch (err) {
        joinFailed.push({ room, error: String(err.message || err) });
      }
    }

    // Set volumes (only for keys the caller provided) — this won't change play/pause state
    const volumeRooms = Object.keys(volumesMap);
    const volResults = await Promise.allSettled(volumeRooms.map(r => setRoomVolume(r, volumesMap[r])));
    const volumes_set = [];
    const volumes_failed = [];
    volResults.forEach((p, i) => {
      const room = volumeRooms[i];
      if (p.status === "fulfilled") volumes_set.push({ room, volume: volumesMap[room] });
      else volumes_failed.push({ room, error: String(p.reason?.message || p.reason) });
    });

    // Response
    res.json({
      ok: true,
      coordinator: coordinatorName,
      mode,
      requested: rooms,
      joined,
      skipped_already_grouped: rooms.filter(r => existing.has(r) || r === coordinatorName),
      failed: joinFailed,
      volumes_set,
      volumes_failed,
      note: zone ? "Active zone found; playback unchanged." : "No active zone; grouped while idle without starting playback."
    });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});


app.listen(Number(PORT), () =>
  console.log(`add-current listening on http://localhost:${PORT}`)
);

