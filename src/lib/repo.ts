import { repositorioLocal, type Repositorio } from "./local";
import { nubeConfigurada, repositorioNube } from "./nube";

/**
 * Con `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` la app habla con
 * BLINK Cloud; sin ellas arranca en modo local con las tarjetas de
 * demostración, para poder probar la interfaz sin backend.
 */
export const repositorio: Repositorio = nubeConfigurada ? repositorioNube : repositorioLocal;

export { ErrorBlink } from "./local";
export type { Repositorio } from "./local";
