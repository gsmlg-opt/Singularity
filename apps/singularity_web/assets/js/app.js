// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import * as DuskmoonHooks from "phoenix_duskmoon/hooks"

// Register only the DuskMoon custom elements this app uses.
import {register as registerButton} from "@duskmoon-dev/el-button"
import {register as registerBadge} from "@duskmoon-dev/el-badge"
import {register as registerAlert} from "@duskmoon-dev/el-alert"
import {register as registerCard} from "@duskmoon-dev/el-card"
registerButton()
registerBadge()
registerAlert()
registerCard()

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...DuskmoonHooks}
})

liveSocket.connect()

// System → Appearance saves the theme preference; apply it without a reload.
window.addEventListener("phx:theme-changed", (event) => window.applyThemePreference(event.detail.theme))

// Expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)
window.liveSocket = liveSocket
