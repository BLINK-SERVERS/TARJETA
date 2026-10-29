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
