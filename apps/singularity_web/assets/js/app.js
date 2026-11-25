// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {DuskmoonLeftMenu, DuskmoonLeftMenuNavigation, DuskmoonPopover} from "duskmoon_phoenix/hooks"
import "@duskmoon-dev/el-alert/register"
import {SourceAutocomplete, TrendingInterval} from "./source_form.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {DuskmoonLeftMenu, DuskmoonLeftMenuNavigation, DuskmoonPopover, SourceAutocomplete, TrendingInterval}
})

liveSocket.connect()

// System → Appearance saves the theme preference; apply it without a reload.
window.addEventListener("phx:theme-changed", (event) => window.applyThemePreference(event.detail.theme))

// Expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket
