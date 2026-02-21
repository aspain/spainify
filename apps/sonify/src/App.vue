<template>
  <div id="app">
    <NowPlaying :player="player" />
  </div>
</template>

<script>
import NowPlaying from '@/components/NowPlaying'

export default {
  name: 'App',
  components: { NowPlaying },

  data() {
    return {
      player: {
        playing: false,
        trackArtists: [],
        trackTitle: '',
        trackKey: '',
        trackAlbum: {
          image: '',
          paletteSrc: ''
        }
      },
      spotifyMetadataBaseUrl:
        process.env.VUE_APP_MEDIA_ACTIONS_BASE ||
        process.env.VUE_APP_ADD_CURRENT_BASE || 'http://localhost:3030',
      spotifyTrackMetaCache: Object.create(null),
      spotifyTrackMetaInFlight: Object.create(null)
    }
  },

  mounted() {
    this.pollSonosState()
  },

  methods: {
    extractSpotifyTrackId(uri) {
      if (!uri) return ''

      const encodedMatch = uri.match(/spotify%3atrack%3a([A-Za-z0-9]+)/)
      if (encodedMatch && encodedMatch[1]) return encodedMatch[1]

      const plainMatch = uri.match(/spotify:track:([A-Za-z0-9]+)/)
      if (plainMatch && plainMatch[1]) return plainMatch[1]

      return ''
    },

    async fetchSpotifyTrackMetadata(trackId) {
      if (!trackId) return null

      if (this.spotifyTrackMetaCache[trackId]) {
        return this.spotifyTrackMetaCache[trackId]
      }

      if (this.spotifyTrackMetaInFlight[trackId]) {
        return this.spotifyTrackMetaInFlight[trackId]
      }

      const request = fetch(
        `${this.spotifyMetadataBaseUrl}/spotify-track/${encodeURIComponent(trackId)}`
      )
        .then(async response => {
          if (!response.ok) return null
          const payload = await response.json()
          if (!payload || payload.ok === false) return null

          const artists = Array.isArray(payload.artists)
            ? payload.artists.filter(Boolean)
            : []

          const metadata = {
            trackId: payload.trackId || trackId,
            title: payload.title || '',
            artists,
            albumImage: payload.albumImage || ''
          }

          this.spotifyTrackMetaCache[trackId] = metadata
          return metadata
        })
        .catch(() => null)
        .finally(() => {
          delete this.spotifyTrackMetaInFlight[trackId]
        })

      this.spotifyTrackMetaInFlight[trackId] = request
      return request
    },

    async enrichPlayerFromSpotify(trackId, expectedTrackKey) {
      const metadata = await this.fetchSpotifyTrackMetadata(trackId)
      if (!metadata) return
      if (!this.player.playing || this.player.trackKey !== expectedTrackKey) return

      const nextTitle = metadata.title || this.player.trackTitle
      const nextArtists = metadata.artists.length
        ? metadata.artists
        : this.player.trackArtists
      const nextImage = metadata.albumImage || this.player.trackAlbum.image
      const nextPaletteSrc = this.player.trackAlbum.paletteSrc || metadata.albumImage

      this.player = {
        playing: this.player.playing,
        trackTitle: nextTitle,
        trackArtists: nextArtists,
        trackKey: this.player.trackKey,
        trackAlbum: {
          image: nextImage,
          paletteSrc: nextPaletteSrc || ''
        }
      }
    },

    /* ─────────────────────────────────────────────────────────────
       Poll Sonos every 2 s, but tolerate short TRANSITIONING gaps
       before we say “nothing is playing”.
       ──────────────────────────────────────────────────────────── */
    async pollSonosState() {
      const GRACE_MS     = 5000;          // 5-second cushion
      let   lastActive   = 0;
      let   lastPlayer   = this.player;
      let   cachedSonosIP = '';           // ← NEW
      let   lastMetadataTrackKey = '';

      const checkState = async () => {
        try {
          const res   = await fetch('http://localhost:5005/zones');
          const zones = await res.json();

          /* 1 ─ Watch whichever zone group the target room belongs to */
          const TARGET =
            process.env.VUE_APP_SONOS_ROOM ||
            process.env.VITE_SONOS_ROOM ||
            'Living Room';

          const activeZone = zones.find(zone =>
            zone.members.some(m => m.roomName === TARGET)
            && zone.members.some(m =>
                  ['PLAYING','TRANSITIONING']
                    .includes(m.state.playbackState)
              )
          );

          if (activeZone) {
            /* 2 ─ Basic track data */
            const coordinator = activeZone.members.find(m => m.coordinator);
            const trackState  = coordinator.state.currentTrack;

            /* ── Discover / remember the speaker’s IP ───────────────────── */
            let sonosIP = coordinator.ip || '';

            // ② pick any *other* member with an IP
            if (!sonosIP) {
              const m = activeZone.members.find(m => m.ip);
              if (m) sonosIP = m.ip;
            }

            // ③ extract host from nextTrack.absoluteAlbumArtUri (old trick)
            if (
              !sonosIP &&
              coordinator.state.nextTrack &&
              coordinator.state.nextTrack.absoluteAlbumArtUri
            ) {
              try {
                sonosIP = new URL(
                  coordinator.state.nextTrack.absoluteAlbumArtUri
                ).hostname;
              } catch (_) { /* ignore parse errors */ }
            }

            // ④ FALL BACK to the cached IP from previous polls
            if (!sonosIP && cachedSonosIP) {
              sonosIP = cachedSonosIP;
            }

            // update cache if we finally got one
            if (sonosIP) cachedSonosIP = sonosIP;

            /* ── Build the artwork URL ─────────────────────────────────── */
            let image = '';

            const hasProg = trackState.albumArtUri
              ? trackState.albumArtUri.includes('x-sonosprog-spotify')
              : false;

            const isSonosHttp = trackState.albumArtUri
              ? trackState.albumArtUri.includes('x-sonos-http')
              : false;

            if (
              (hasProg || isSonosHttp || !trackState.albumArtUri) &&
              trackState.absoluteAlbumArtUri &&
              trackState.absoluteAlbumArtUri.startsWith('http')
            ) {
              // artist-radio or albumArtUri missing → use absoluteAlbumArtUri
              image = trackState.absoluteAlbumArtUri;
            } else if (trackState.albumArtUri) {
              if (trackState.albumArtUri.startsWith('http')) {
                image = trackState.albumArtUri;                    // full URL
              } else if (sonosIP) {
                image = `http://${sonosIP}:1400${trackState.albumArtUri}`; // preferred
              } else if (
                trackState.absoluteAlbumArtUri &&
                trackState.absoluteAlbumArtUri.startsWith('http')
              ) {
                image = trackState.absoluteAlbumArtUri;            // last resort
              }
            }

            /* CORS-safe copy for node-vibrant */
            const paletteSrc =
              image.includes(':1400/') || image.includes(`://${sonosIP}:1400`)
                ? `http://localhost:5005/album-art?url=${encodeURIComponent(image)}`
                : image;

            const trackTitle = trackState.title || ''
            const trackArtist = trackState.artist || ''
            const trackId = this.extractSpotifyTrackId(trackState.uri || '')
            const cachedSpotifyMetadata = trackId
              ? this.spotifyTrackMetaCache[trackId]
              : null

            /* Update reactive data */
            const trackKey =
              trackId ||
              trackState.uri ||
              [
                trackTitle,
                trackArtist,
                trackState.absoluteAlbumArtUri,
                trackState.albumArtUri
              ]
                .filter(Boolean)
                .join('::')

            const resolvedTitle =
              cachedSpotifyMetadata && cachedSpotifyMetadata.title
                ? cachedSpotifyMetadata.title
                : trackTitle

            const resolvedArtists =
              cachedSpotifyMetadata &&
              Array.isArray(cachedSpotifyMetadata.artists) &&
              cachedSpotifyMetadata.artists.length > 0
                ? cachedSpotifyMetadata.artists
                : (trackArtist ? [trackArtist] : [])

            const resolvedImage =
              cachedSpotifyMetadata && cachedSpotifyMetadata.albumImage
                ? cachedSpotifyMetadata.albumImage
                : image

            const resolvedPaletteSrc =
              paletteSrc ||
              (
                cachedSpotifyMetadata && cachedSpotifyMetadata.albumImage
                  ? cachedSpotifyMetadata.albumImage
                  : ''
              )

            this.player = {
              playing: true,
              trackTitle: resolvedTitle,
              trackArtists: resolvedArtists,
              trackKey,
              trackAlbum: {
                image: resolvedImage,
                paletteSrc: resolvedPaletteSrc
              }
            };

            if (trackId && !cachedSpotifyMetadata && trackKey !== lastMetadataTrackKey) {
              lastMetadataTrackKey = trackKey
              this.enrichPlayerFromSpotify(trackId, trackKey)
            } else if (!trackId) {
              lastMetadataTrackKey = trackKey
            }

            lastActive = Date.now();
            lastPlayer = this.player;
          } else {
            /* 3 ─ No active zone; grace period avoids flicker */
            if (Date.now() - lastActive > GRACE_MS) {
              this.player.playing = false;   // show idle
              lastMetadataTrackKey = ''
            } else {
              this.player = lastPlayer;      // keep showing last track
            }
          }
        } catch (err) {
          console.error('Sonos API error:', err);
        }
      };

      checkState();
      setInterval(checkState, 2000);
    }
  }
}
</script>
