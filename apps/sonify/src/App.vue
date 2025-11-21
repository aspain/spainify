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
        trackAlbum: {
          image: '',
          paletteSrc: ''
        }
      }
    }
  },

  mounted() {
    this.pollSonosState()
  },

  methods: {
    /* ─────────────────────────────────────────────────────────────
       Poll Sonos every 2 s, but tolerate short TRANSITIONING gaps
       before we say “nothing is playing”.
       ──────────────────────────────────────────────────────────── */
    async pollSonosState() {
      const GRACE_MS     = 5000;          // 5-second cushion
      let   lastActive   = 0;
      let   lastPlayer   = this.player;
      let   cachedSonosIP = '';           // ← NEW

      const checkState = async () => {
        try {
          const res   = await fetch('http://localhost:5005/zones');
          const zones = await res.json();

          /* 1 ─ Watch whichever zone group Living Room belongs to */
          const TARGET = 'Living Room';

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

            /* Update reactive data */
            this.player = {
              playing: true,
              trackTitle: trackState.title,
              trackArtists: [trackState.artist],
              trackAlbum: { image, paletteSrc }
            };

            lastActive = Date.now();
            lastPlayer = this.player;
          } else {
            /* 3 ─ No active zone; grace period avoids flicker */
            if (Date.now() - lastActive > GRACE_MS) {
              this.player.playing = false;   // show idle
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
