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
  SPOTIFY_PLAYLIST_ID: SPOTIFY_PLAYLIST_RAW,
  SONOS_HTTP_BASE = "http://127.0.0.1:5005",
  PREFERRED_ROOM = "",
  DE_DUPE_WINDOW = "250",
  PORT = 3030
} = process.env;

const app = express();

app.use(express.json());
app.use((req, res, next) => {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type,Authorization");
  if (req.method === "OPTIONS") {
    res.sendStatus(204);
    return;
  }
  next();
});

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

function normalizeSpotifyPlaylistId(value) {
  const raw = String(value || "").trim();
  if (!raw) return "";

  const uriMatch = raw.match(/spotify:playlist:([A-Za-z0-9]+)/);
  if (uriMatch) return uriMatch[1];

  const urlMatch = raw.match(/open\.spotify\.com\/playlist\/([A-Za-z0-9]+)/);
  if (urlMatch) return urlMatch[1];

  if (/^[A-Za-z0-9]+$/.test(raw)) return raw;
  return raw;
}

const SPOTIFY_PLAYLIST_ID = normalizeSpotifyPlaylistId(SPOTIFY_PLAYLIST_RAW);

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
  return zone.members.some(m => m.state?.playbackState === "PLAYING");
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

function zoneSortKey(zone) {
  const coordinatorName = String(coordinatorOf(zone)?.roomName || "").toLowerCase();
  const members = Array.isArray(zone?.members) ? zone.members : [];
  const memberNames = members
    .map(m => String(m?.roomName || "").toLowerCase())
    .filter(Boolean)
    .sort()
    .join("|");
  return `${coordinatorName}::${memberNames}`;
}

function sortZonesDeterministically(zones) {
  return [...zones].sort((a, b) => zoneSortKey(a).localeCompare(zoneSortKey(b)));
}

/**
 * Pick the best active zone:
 * 1) If a room is specified, return that active room (respecting mode filter)
 * 2) Prefer zones that have a Spotify track
 * 3) Else, any zone that looks like music (not TV/line-in)
 * 4) Else, any active zone (last resort)
 *
 * When multiple zones match the same priority, choose deterministically
 * by coordinator/member room names (stable tie-breaker).
 *
 * mode: "music" (default) ignores TV/line-in, "any" doesn’t filter.
 */
function pickActiveZone(zones, preferredRoom, mode = "music") {
  const active = sortZonesDeterministically(zones.filter(isActive));
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

let cachedAccessToken = "";
let cachedAccessTokenExpiresAt = 0;
const ACCESS_TOKEN_SKEW_MS = 30 * 1000;

function clearAccessTokenCache() {
  cachedAccessToken = "";
  cachedAccessTokenExpiresAt = 0;
}

async function getAccessToken({ forceRefresh = false } = {}) {
  if (
    !forceRefresh &&
    cachedAccessToken &&
    Date.now() < (cachedAccessTokenExpiresAt - ACCESS_TOKEN_SKEW_MS)
  ) {
    return cachedAccessToken;
  }

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
  cachedAccessToken = j.access_token || "";
  const expiresInSec = Number(j.expires_in || 3600);
  cachedAccessTokenExpiresAt = Date.now() + (expiresInSec * 1000);
  return cachedAccessToken;
}

async function spotifyRequest(makeRequest) {
  let token = await getAccessToken();
  let response = await makeRequest(token);
  if (response.status === 401) {
    clearAccessTokenCache();
    token = await getAccessToken({ forceRefresh: true });
    response = await makeRequest(token);
  }
  return response;
}

async function fetchSpotifyJsonWithRetry(url, retries = 3, timeoutMs = 4000) {
  let token = await getAccessToken();

  for (let refreshAttempt = 0; refreshAttempt < 2; refreshAttempt++) {
    try {
      return await fetchJsonWithRetry(
        url,
        { headers: { Authorization: `Bearer ${token}` } },
        retries,
        timeoutMs
      );
    } catch (err) {
      const msg = String(err?.message || err);
      if (refreshAttempt === 0 && msg.startsWith("401")) {
        clearAccessTokenCache();
        token = await getAccessToken({ forceRefresh: true });
        continue;
      }
      throw err;
    }
  }

  throw new Error("Spotify request retry exhausted");
}

async function addTrackToPlaylist(trackId) {
  if (!SPOTIFY_PLAYLIST_ID) throw new Error("Missing SPOTIFY_PLAYLIST_ID");
  const r = await spotifyRequest(token => fetch(
    `https://api.spotify.com/v1/playlists/${SPOTIFY_PLAYLIST_ID}/tracks`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify({ uris: [`spotify:track:${trackId}`] })
    }
  ));
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

const DEFAULT_DE_DUPE_WINDOW = 250;
const DEFAULT_PLAYLIST_CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const parsedPlaylistCacheTtlMs = Number(process.env.PLAYLIST_CACHE_TTL_MS || DEFAULT_PLAYLIST_CACHE_TTL_MS);
const PLAYLIST_CACHE_TTL_MS =
  Number.isFinite(parsedPlaylistCacheTtlMs) && parsedPlaylistCacheTtlMs > 0
    ? parsedPlaylistCacheTtlMs
    : DEFAULT_PLAYLIST_CACHE_TTL_MS;

const playlistCache = {
  ids: new Set(),
  snapshotId: "",
  total: 0,
  scopeKey: "",
  updatedAt: 0
};
let playlistCacheRefreshPromise = null;

function getDedupeWindow() {
  const raw = String(DE_DUPE_WINDOW || "").trim().toLowerCase();
  if (["all", "full", "entire", "none", "0"].includes(raw)) {
    return null; // null means scan entire playlist
  }
  const n = Number(raw || DEFAULT_DE_DUPE_WINDOW);
  if (!Number.isFinite(n) || n < 1) return DEFAULT_DE_DUPE_WINDOW;
  return Math.floor(n);
}

function dedupeScopeKey(windowSize) {
  return windowSize == null ? "all" : `last:${windowSize}`;
}

function isPlaylistCacheUsable(windowSize) {
  const scopeKey = dedupeScopeKey(windowSize);
  return (
    playlistCache.updatedAt > 0 &&
    playlistCache.scopeKey === scopeKey &&
    (Date.now() - playlistCache.updatedAt) < PLAYLIST_CACHE_TTL_MS
  );
}

function markPlaylistCacheWithAddedTrack(trackId, windowSize) {
  const scopeKey = dedupeScopeKey(windowSize);
  if (!trackId) return;
  if (playlistCache.scopeKey !== scopeKey || playlistCache.updatedAt === 0) return;
  const previousSize = playlistCache.ids.size;
  playlistCache.ids.add(trackId);
  if (playlistCache.ids.size > previousSize) playlistCache.total += 1;
  playlistCache.updatedAt = Date.now();
}

async function fetchPlaylistMeta() {
  const url = `https://api.spotify.com/v1/playlists/${SPOTIFY_PLAYLIST_ID}?fields=snapshot_id,tracks(total)`;
  const j = await fetchSpotifyJsonWithRetry(url);
  return {
    snapshotId: String(j?.snapshot_id || ""),
    total: Math.max(0, Number(j?.tracks?.total || 0))
  };
}

async function scanPlaylistTrackIds(windowSize, total) {
  const ids = new Set();
  const base = `https://api.spotify.com/v1/playlists/${SPOTIFY_PLAYLIST_ID}/tracks`;
  const end = Math.max(0, total);
  let offset = windowSize == null ? 0 : Math.max(0, end - windowSize);

  while (offset < end) {
    const limit = Math.min(100, end - offset);
    const url = `${base}?fields=items(track(id))&limit=${limit}&offset=${offset}`;
    const j = await fetchSpotifyJsonWithRetry(url);
    for (const it of (j.items || [])) {
      const id = it?.track?.id;
      if (id) ids.add(id);
    }
    const got = (j.items || []).length;
    if (got === 0) break;
    offset += got;
  }

  return ids;
}

async function refreshPlaylistCache(windowSize, meta = null) {
  if (playlistCacheRefreshPromise) return playlistCacheRefreshPromise;
  const scopeKey = dedupeScopeKey(windowSize);

  playlistCacheRefreshPromise = (async () => {
    const resolvedMeta = meta || await fetchPlaylistMeta();
    const ids = await scanPlaylistTrackIds(windowSize, resolvedMeta.total);
    playlistCache.ids = ids;
    playlistCache.snapshotId = resolvedMeta.snapshotId || "";
    playlistCache.total = resolvedMeta.total;
    playlistCache.scopeKey = scopeKey;
    playlistCache.updatedAt = Date.now();
    return playlistCache;
  })();

  try {
    return await playlistCacheRefreshPromise;
  } finally {
    playlistCacheRefreshPromise = null;
  }
}

async function playlistHasTrackDirect(trackId, windowSize) {
  const base = `https://api.spotify.com/v1/playlists/${SPOTIFY_PLAYLIST_ID}/tracks`;

  // 1) Get total
  const meta = await fetchSpotifyJsonWithRetry(`${base}?limit=1`);
  const total = Number(meta.total || 0);

  // 2) Scan from the end (most recent first)
  let offset = windowSize == null ? 0 : Math.max(0, total - windowSize);
  const end = total;

  while (offset < end) {
    const limit = Math.min(100, end - offset);
    const url = `${base}?fields=items(track(id))&limit=${limit}&offset=${offset}`;
    const j = await fetchSpotifyJsonWithRetry(url);
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

async function playlistHasTrackCached(trackId, windowSize) {
  if (!isPlaylistCacheUsable(windowSize)) {
    await refreshPlaylistCache(windowSize);
    return playlistCache.ids.has(trackId);
  }

  // Lightweight revalidation so external playlist changes don't stale the cache.
  const meta = await fetchPlaylistMeta();
  const snapshotChanged =
    !!meta.snapshotId &&
    !!playlistCache.snapshotId &&
    meta.snapshotId !== playlistCache.snapshotId;

  if (snapshotChanged || meta.total !== playlistCache.total) {
    await refreshPlaylistCache(windowSize, meta);
  } else {
    playlistCache.updatedAt = Date.now();
  }

  return playlistCache.ids.has(trackId);
}

/** Check playlist for duplicates using configured scope (last N or full playlist). */
async function playlistHasTrack(trackId) {
  const windowSize = getDedupeWindow();
  try {
    return await playlistHasTrackCached(trackId, windowSize);
  } catch {
    return playlistHasTrackDirect(trackId, windowSize);
  }
}


/** Use Spotify API to get the currently playing track for this account. */
async function getSpotifyCurrentlyPlayingTrack() {
  const r = await spotifyRequest(token => fetch(
    "https://api.spotify.com/v1/me/player/currently-playing",
    { headers: { Authorization: `Bearer ${token}` } }
  ));

  if (r.status === 204) return null; // nothing playing
  if (!r.ok) throw new Error(`Currently-playing failed: ${r.status} ${await r.text()}`);

  const j = await r.json();
  if (!j?.is_playing) return null; // ignore paused sessions
  if (j.currently_playing_type !== "track") return null; // ignore podcasts, etc.

  const id = j?.item?.id;
  if (!id) return null;

  const title = j?.item?.name || null;
  const artist = (j?.item?.artists?.[0]?.name) || null;

  return { trackId: id, title, artist };
}

async function getSpotifyTrackById(trackId) {
  if (!trackId) throw new Error("Missing trackId");
  const url = `https://api.spotify.com/v1/tracks/${encodeURIComponent(trackId)}`;
  const j = await fetchSpotifyJsonWithRetry(url, 2, 4000);

  const artists = Array.isArray(j?.artists)
    ? j.artists.map(a => a?.name).filter(Boolean)
    : [];

  const albumImage =
    Array.isArray(j?.album?.images) && j.album.images.length > 0
      ? (j.album.images[0]?.url || "")
      : "";

  return {
    trackId: j?.id || trackId,
    title: j?.name || "",
    artists,
    albumImage,
    albumName: j?.album?.name || "",
    uri: j?.uri || "",
    durationMs: Number.isFinite(Number(j?.duration_ms))
      ? Number(j.duration_ms)
      : null
  };
}

/* ───────────────────────── Endpoints ───────────────────────── */

app.get("/health", (_req, res) => res.json({ ok: true }));

app.get("/spotify-track/:trackId", async (req, res) => {
  try {
    if (!SPOTIFY_CLIENT_ID || !SPOTIFY_CLIENT_SECRET || !SPOTIFY_REFRESH_TOKEN) {
      return res.status(503).json({
        ok: false,
        error: "Spotify API credentials are not configured on media-actions-api"
      });
    }

    const trackId = String(req.params.trackId || "").trim();
    if (!/^[A-Za-z0-9]{8,64}$/.test(trackId)) {
      return res.status(400).json({ ok: false, error: "Invalid Spotify track id" });
    }

    const track = await getSpotifyTrackById(trackId);
    return res.json({ ok: true, ...track });
  } catch (e) {
    const message = String(e?.message || e);
    if (message.startsWith("404")) {
      return res.status(404).json({ ok: false, error: "Track not found on Spotify" });
    }
    if (message.startsWith("401")) {
      return res.status(401).json({ ok: false, error: "Spotify auth failed" });
    }
    return res.status(500).json({ ok: false, error: message });
  }
});

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
      // Default behavior: choose best active zone globally.
      // Optional ?room=... can force room preference per request.
      zone  = pickActiveZone(zones, roomOverride || "", mode);

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
    const windowSize = getDedupeWindow();
    markPlaylistCacheWithAddedTrack(picked.trackId, windowSize);
    refreshPlaylistCache(windowSize).catch(() => {});

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
  console.log(`media-actions-api listening on http://localhost:${PORT}`)
);
