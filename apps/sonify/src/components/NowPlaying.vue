<template>
  <div id="app">
    <div
      v-if="player.playing"
      class="now-playing"
      :class="getNowPlayingClass()"
    >
      <div class="now-playing__cover">
        <img
          :src="player.trackAlbum.image"
          :alt="player.trackTitle"
          class="now-playing__image"
        />
      </div>
      <div class="now-playing__details">
        <h1 class="now-playing__track" v-text="player.trackTitle"></h1>
        <h2 class="now-playing__artists" v-text="getTrackArtists"></h2>
      </div>
    </div>
    <div v-else class="now-playing" :class="getNowPlayingClass()">
      <h1 class="now-playing__idle-heading">No music is playing 😔</h1>
    </div>
  </div>
</template>

<script>
import * as Vibrant from 'node-vibrant'

export default {
  name: 'NowPlaying',

  props: {
    player: {
      type: Object,
      required: true,
      default: () => ({
        playing: false,
        trackAlbum: {},
        trackArtists: [],
        trackTitle: ''
      })
    }
  },

  computed: {
    getTrackArtists() {
      if (Array.isArray(this.player.trackArtists)) {
        return this.player.trackArtists.join(', ')
      }
      return this.player.trackArtists || ''
    }
  },

  methods: {
    getNowPlayingClass() {
      return this.player.playing ? 'now-playing--active' : 'now-playing--idle'
    },

    updateColors(imageUrl) {
      if (!imageUrl) return

      Vibrant.from(imageUrl)
        .quality(1)
        .clearFilters()
        .getPalette()
        .then(palette => {
          const swatches = Object.values(palette).filter(Boolean)
          if (swatches.length > 0) {
            const randomSwatch = swatches[Math.floor(Math.random() * swatches.length)]
            const bgColor = randomSwatch.getHex()
            const textColor = this.calculateTextColor(bgColor)

            document.documentElement.style.setProperty(
              '--color-text-primary',
              textColor
            )
            document.documentElement.style.setProperty(
              '--colour-background-now-playing',
              bgColor
            )
          }
        })
        .catch(console.error)
    },

    calculateTextColor(bgHex) {
      const c = bgHex.replace('#', '')
      const rgb = parseInt(c, 16)
      const r = (rgb >> 16) & 0xff
      const g = (rgb >> 8) & 0xff
      const b = (rgb >> 0) & 0xff
      const brightness = 0.299 * r + 0.587 * g + 0.114 * b
      return brightness > 150 ? '#000' : '#fff'
    }
  },

  watch: {
    /* NEW — pass the proxied URL to Vibrant so CORS never blocks us */
    'player.trackAlbum.paletteSrc': {
      immediate: true,
      handler(newVal) {
        if (newVal) this.updateColors(newVal)
      }
    }
  }
}
</script>

<style src="@/styles/components/now-playing.scss" lang="scss" scoped></style>