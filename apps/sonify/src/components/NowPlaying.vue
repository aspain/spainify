<template>
  <div id="app">
    <div
      v-if="player.playing"
      class="now-playing"
      :class="getNowPlayingClass()"
      ref="nowPlaying"
    >
      <div class="now-playing__cover">
        <img
          :src="player.trackAlbum.image"
          :alt="player.trackTitle"
          class="now-playing__image"
        />
      </div>
      <div class="now-playing__details">
        <h1
          ref="trackText"
          class="now-playing__track"
          v-text="player.trackTitle"
        ></h1>
        <h2
          ref="artistsText"
          class="now-playing__artists"
          v-text="getTrackArtists"
        ></h2>
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

  data() {
    return {
      titleNeedsExtended: false,
      artistsNeedExtended: false,
      boostMode: 'none',
      overflowCheckRaf: 0
    }
  },

  props: {
    player: {
      type: Object,
      required: true,
      default: () => ({
        playing: false,
        trackAlbum: {},
        trackArtists: [],
        trackKey: '',
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
    },

    colorRefreshKey() {
      if (!this.player.playing) return ''

      const trackKey = this.player.trackKey || ''
      const paletteSrc =
        this.player.trackAlbum && this.player.trackAlbum.paletteSrc
          ? this.player.trackAlbum.paletteSrc
          : ''

      return `${trackKey}::${paletteSrc}`
    }
  },

  mounted() {
    window.addEventListener('resize', this.handleWindowResize)
    this.scheduleOverflowCheck()
  },

  beforeDestroy() {
    window.removeEventListener('resize', this.handleWindowResize)
    if (this.overflowCheckRaf) {
      window.cancelAnimationFrame(this.overflowCheckRaf)
      this.overflowCheckRaf = 0
    }
  },

  methods: {
    getNowPlayingClass() {
      const classes = [
        this.player.playing ? 'now-playing--active' : 'now-playing--idle'
      ]

      if (this.titleNeedsExtended) classes.push('now-playing--title-extended')
      if (this.artistsNeedExtended) classes.push('now-playing--artists-extended')
      if (this.boostMode === 'soft') classes.push('now-playing--boost-soft')
      if (this.boostMode === 'strong') classes.push('now-playing--boost-strong')

      return classes
    },

    handleWindowResize() {
      this.scheduleOverflowCheck()
    },

    scheduleOverflowCheck() {
      if (this.overflowCheckRaf) {
        window.cancelAnimationFrame(this.overflowCheckRaf)
        this.overflowCheckRaf = 0
      }

      this.$nextTick(() => {
        this.overflowCheckRaf = window.requestAnimationFrame(() => {
          this.overflowCheckRaf = 0
          this.updateOverflowState()
        })
      })
    },

    getElementOverflow(element) {
      if (!element) return false
      const EPSILON_PX = 2
      return (
        element.scrollHeight - element.clientHeight > EPSILON_PX ||
        element.scrollWidth - element.clientWidth > EPSILON_PX
      )
    },

    getNowPlayingOverflow() {
      return {
        track: this.getElementOverflow(this.$refs.trackText),
        artists: this.getElementOverflow(this.$refs.artistsText)
      }
    },

    async updateOverflowState() {
      if (!this.player.playing) {
        this.titleNeedsExtended = false
        this.artistsNeedExtended = false
        this.boostMode = 'none'
        return
      }

      const trackElement = this.$refs.trackText
      const artistsElement = this.$refs.artistsText
      if (!trackElement || !artistsElement) return

      // Baseline state: 3-line title / 2-line artists with no boost.
      this.titleNeedsExtended = false
      this.artistsNeedExtended = false
      this.boostMode = 'none'
      await this.$nextTick()

      const baseOverflow = this.getNowPlayingOverflow()
      this.titleNeedsExtended = baseOverflow.track
      this.artistsNeedExtended = baseOverflow.artists

      if (this.titleNeedsExtended || this.artistsNeedExtended) {
        this.boostMode = 'none'
        return
      }

      // Try strong boost first, then fall back to soft, then none.
      this.boostMode = 'strong'
      await this.$nextTick()
      const strongOverflow = this.getNowPlayingOverflow()
      if (!strongOverflow.track && !strongOverflow.artists) {
        return
      }

      this.boostMode = 'soft'
      await this.$nextTick()
      const softOverflow = this.getNowPlayingOverflow()
      if (!softOverflow.track && !softOverflow.artists) {
        return
      }

      this.boostMode = 'none'
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
            const selectedSwatch = this.pickBackgroundSwatch(swatches)
            const bgColor = selectedSwatch.getHex()
            const textColor = this.getBestTextColor(bgColor)

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

    pickBackgroundSwatch(swatches) {
      if (!swatches.length) return null

      const spiceChance = 0.1
      if (Math.random() < spiceChance) {
        return swatches[Math.floor(Math.random() * swatches.length)]
      }

      const weightedSwatches = swatches.map(swatch => ({
        swatch,
        weight: this.getSwatchWeight(swatch)
      }))

      const totalWeight = weightedSwatches.reduce(
        (sum, item) => sum + item.weight,
        0
      )

      if (totalWeight <= 0) {
        return swatches[Math.floor(Math.random() * swatches.length)]
      }

      let roll = Math.random() * totalWeight
      for (const item of weightedSwatches) {
        roll -= item.weight
        if (roll <= 0) {
          return item.swatch
        }
      }

      return weightedSwatches[weightedSwatches.length - 1].swatch
    },

    getSwatchWeight(swatch) {
      const hsl = swatch.getHsl()
      if (!Array.isArray(hsl) || hsl.length < 3) {
        return 1
      }

      const saturation = hsl[1]
      const lightness = hsl[2]

      const saturationScore = 1 - Math.min(Math.abs(saturation - 0.55) / 0.55, 1)
      const lightnessScore = 1 - Math.min(Math.abs(lightness - 0.4) / 0.4, 1)

      let weight = 0.2 + saturationScore * 0.9 + lightnessScore * 0.9

      if (saturation > 0.8 && lightness > 0.55) weight *= 0.35
      if (lightness < 0.12) weight *= 0.5
      if (lightness > 0.75) weight *= 0.5

      return Math.max(weight, 0.05)
    },

    getBestTextColor(bgHex) {
      const bgRgb = this.hexToRgb(bgHex)
      if (!bgRgb) return '#fff'

      const whiteContrast = this.getContrastRatio(bgRgb, { r: 255, g: 255, b: 255 })
      const blackContrast = this.getContrastRatio(bgRgb, { r: 0, g: 0, b: 0 })

      return blackContrast >= whiteContrast ? '#000' : '#fff'
    },

    hexToRgb(hex) {
      const normalizedHex = hex.replace('#', '')
      if (normalizedHex.length !== 6) return null

      const parsed = parseInt(normalizedHex, 16)
      if (Number.isNaN(parsed)) return null

      return {
        r: (parsed >> 16) & 0xff,
        g: (parsed >> 8) & 0xff,
        b: parsed & 0xff
      }
    },

    getRelativeLuminance({ r, g, b }) {
      const toLinear = channel => {
        const srgb = channel / 255
        return srgb <= 0.03928
          ? srgb / 12.92
          : Math.pow((srgb + 0.055) / 1.055, 2.4)
      }

      const red = toLinear(r)
      const green = toLinear(g)
      const blue = toLinear(b)

      return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    },

    getContrastRatio(rgbA, rgbB) {
      const luminanceA = this.getRelativeLuminance(rgbA)
      const luminanceB = this.getRelativeLuminance(rgbB)
      const lighter = Math.max(luminanceA, luminanceB)
      const darker = Math.min(luminanceA, luminanceB)

      return (lighter + 0.05) / (darker + 0.05)
    }
  },

  watch: {
    colorRefreshKey: {
      immediate: true,
      handler() {
        const paletteSrc =
          this.player.trackAlbum && this.player.trackAlbum.paletteSrc
            ? this.player.trackAlbum.paletteSrc
            : ''
        if (this.player.playing && paletteSrc) {
          this.updateColors(paletteSrc)
        }

        this.scheduleOverflowCheck()
      }
    },

    getTrackArtists() {
      this.scheduleOverflowCheck()
    },

    'player.trackTitle'() {
      this.scheduleOverflowCheck()
    },

    'player.playing'(isPlaying) {
      if (!isPlaying) {
        this.titleNeedsExtended = false
        this.artistsNeedExtended = false
        this.boostMode = 'none'
      }
      this.scheduleOverflowCheck()
    }
  }
}
</script>

<style src="@/styles/components/now-playing.scss" lang="scss" scoped></style>
