import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";

import "./styles/fonts.css";
import "./styles/base.css";
import "./styles/tokens.css";
import "./styles/app.css";

const el = document.getElementById("root");
if (!el) throw new Error("No se encontró #root");

createRoot(el).render(
  <StrictMode>
    <App />
  </StrictMode>
);

// El service worker guarda el armazón y los recursos del portal para que las
// siguientes visitas abran sin red. La primera carga ocurre antes de que el
// worker controle la página, así que se le envían las URLs ya vistas.
if (import.meta.env.PROD && "serviceWorker" in navigator) {
  window.addEventListener("load", async () => {
    try {
      const registro = await navigator.serviceWorker.register(
        `${import.meta.env.BASE_URL}sw.js`,
        { updateViaCache: "none" }
      );
      await navigator.serviceWorker.ready;
      const urls = Array.from(
        new Set([
          window.location.href,
          ...performance.getEntriesByType("resource").map((entrada) => entrada.name),
        ])
      ).filter((url) => url.startsWith(window.location.origin));
      registro.active?.postMessage({ tipo: "cachear", urls });
    } catch {
      // Sin service worker la app sigue funcionando en línea.
    }
  });
}
