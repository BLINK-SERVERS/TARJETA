/* BLINK TARJETA — capa offline.
   El primer arranque en línea cachea el armazón y, tras tomar el control,
   los recursos con hash. Las llamadas a Supabase son de otro origen y no
   pasan por aquí. Al cambiar la lógica, subir CACHE para borrar la vieja. */
const CACHE = "blink-tarjeta-v1";
const RAIZ = new URL("./", self.location).href;
const ARMAZON = [
  RAIZ,
  RAIZ + "index.html",
  RAIZ + "manifest.webmanifest",
  RAIZ + "icon.png",
  RAIZ + "favicon.svg",
  RAIZ + "qr-portal.svg",
];

self.addEventListener("install", (evento) => {
  evento.waitUntil(
    caches
      .open(CACHE)
      .then((cache) => cache.addAll(ARMAZON))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (evento) => {
  evento.waitUntil(
    caches
      .keys()
      .then((claves) =>
        Promise.all(
          claves.filter((clave) => clave !== CACHE).map((clave) => caches.delete(clave))
        )
      )
      .then(() => self.clients.claim())
  );
});

// La primera visita carga los recursos antes de que el worker controle la
// página; desde `main.tsx` se envían las URLs vistas para guardarlas aquí.
self.addEventListener("message", (evento) => {
  const datos = evento.data;
  if (!datos || datos.tipo !== "cachear" || !Array.isArray(datos.urls)) return;
  evento.waitUntil(
    caches.open(CACHE).then((cache) =>
      Promise.all(datos.urls.map((url) => cache.add(url).catch(() => {})))
    )
  );
});

async function redPrimero(peticion) {
  const cache = await caches.open(CACHE);
  try {
    const respuesta = await fetch(peticion);
    if (respuesta && respuesta.ok) await cache.put(peticion, respuesta.clone());
    return respuesta;
  } catch {
    return (
      (await cache.match(peticion)) ||
      (await cache.match(RAIZ + "index.html")) ||
      Response.error()
    );
  }
}

self.addEventListener("fetch", (evento) => {
  const peticion = evento.request;
  if (peticion.method !== "GET") return;

  const url = new URL(peticion.url);
  if (url.origin !== self.location.origin) return;

  if (peticion.mode === "navigate") {
    evento.respondWith(redPrimero(peticion));
    return;
  }

  evento.respondWith(
    caches.open(CACHE).then(async (cache) => {
      const guardada = await cache.match(peticion);
      if (guardada) return guardada;
      try {
        const respuesta = await fetch(peticion);
        if (respuesta && respuesta.ok && respuesta.type === "basic") {
          await cache.put(peticion, respuesta.clone());
        }
        return respuesta;
      } catch {
        return Response.error();
      }
    })
  );
});
