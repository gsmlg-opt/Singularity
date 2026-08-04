import "phoenix_html";

import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

import { Hooks } from "./hooks";

const csrfToken =
  document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.getAttribute("content") ?? "";

const liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: { _csrf_token: csrfToken },
});

liveSocket.connect();

if (import.meta.hot) {
  import.meta.hot.accept();
}
