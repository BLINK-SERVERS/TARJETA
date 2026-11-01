# Guía para retomar el desarrollo

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-10 |
| Versión | 1.4.0 |
| Fecha | 2026-10-31 |
| Estado | Vigente |
| Norma | ISO/IEC/IEEE 26515 |

## 1. En diez minutos

1. Lee el [índice](README.md) y la [arquitectura](02-arquitectura.md).
2. Todo el material BLINK vive en `~/BLINK` (ver su `README.md`). Los repositorios
   vigentes de la organización `BLINK-SERVERS` son `TARJETA`, `BACKOFFICE`,
   `PASAJES-REDIRECT` y `POS`; `PASAJES` está archivado y no se clona.
3. Instala Node 22+, `gh`, `psql` y `docker-compose`; autentica con
   `gh auth login`.
4. Ejecuta `npm ci && npm test` en `tarjeta/` y `npm ci && npm run typecheck`
   en `backoffice/`.
5. TARJETA sin `.env.local` funciona en **modo demostración**; para la nube pide
   las variables a quien administre el proyecto Supabase.
6. Antes de tocar el flujo, ejecuta `cd ~/BLINK/simulacion && ./arrancar.sh && ./flujo.sh`.
7. Para tocar la base real, pide la contraseña al gestor de secretos (nunca por
   chat).

## 2. Mapa mental

```text
~/BLINK/
  README.md                        mapa de carpetas y comandos rápidos
  tarjeta/                         ← portal del pasajero + esquema compartido
    src/pages/                     Acceso, Inicio, Movimientos, Recargar, Perfil
    src/lib/repo.ts                selector nube/local
    src/lib/nube.ts                cliente RPC (contrato en BLINK-DOC-04)
    src/lib/local.ts               espejo local del contrato
    src/components/TarjetaVirtual.tsx  tarjeta ID-1 con giro 3D
    src/styles/app.css             tarjeta con container queries (cqw)
    supabase/migrations/           0001…0018
    scripts/lote.ts                generación de lotes y hoja de impresión
    docs/                          esta suite
    simulacion/                    pila Docker + flujo.mjs + scripts

  backoffice/                      ← consola administrativa (rol ADMIN/TAQUILLA + TOTP)
    src/lib/api.ts                 cliente RPC con token de sesión (BLINK-DOC-04 §4)
    src/lib/serial.ts              lector ESP32 por Web Serial
    src/pages/Acceso.tsx, Mfa.tsx  login cédula+PIN y alta del segundo factor
    src/pages/Resumen.tsx          totales operativos del día
    src/pages/Recargas.tsx         bandeja de Pago Móvil: aprobar o rechazar
    src/pages/Lotes.tsx            creación de lotes y exportación CSV
    src/pages/Inventario.tsx       filtros por lote, serial y estado
    src/pages/Estacion.tsx         captura UID y carga masiva

  pos/pos/app/                     ← comercio (Supabase Auth + RLS), producto aparte
  firmware/lector/, firmware/validador/   sketches ESP32
  documentacion/fuentes/           diseño técnico y guías originales (.md)
  documentacion/hardware/          datasheets, índice y paquetes Arduino
  archivo/pasajes/                 copia histórica de BLINK PASAJES (retirado)
```

Los enlaces `~/BLINK_Tarjeta`, `~/BLINK_Backoffice`, `~/BLINK_POS_Project`,
`~/BLINK_Pasajes_Project`, `~/Arduino/BLINK_*` y `~/Documentación` apuntan a las
carpetas nuevas para no romper hábitos ni scripts.

## 3. Cómo añadir una función al portal

1. **Base de datos:** nueva migración con el número siguiente (`0017_*.sql`) con
   la función `bt_*` (`security definer`, `search_path` fijo) y sus
   `revoke`/`grant`.
2. **Contrato:** añade el método en `src/lib/nube.ts` y su gemelo en
   `src/lib/local.ts`. Si la función es de operación, añade además el envoltorio
   `bt_admin_*` con `p_token` y su método en `BACKOFFICE/src/lib/api.ts`
   (BLINK-DOC-04 §4).
3. **Repositorio:** expón el método en `src/lib/repo.ts`.
4. **UI:** consume el repositorio desde la página; nunca `fetch` directo.
5. **Pruebas:** unidad en `src/lib/*.test.ts`; flujo SQL con `SET LOCAL ROLE anon`
   y `ROLLBACK`.
6. **Documentación:** BLINK-DOC-03/04 y `CHANGELOG.md` en el mismo commit.

## 4. Convenciones

- **TypeScript estricto**; sin `any` nuevos.
- **Nombres:** dominio en español (`Cuenta`, `Tarjeta`, `DatosPago`), tipos
  externos en el idioma del backend (`cards`, `recharges`).
- **CSS:** BEM (`bloque__elemento--modificador`), tokens en `src/styles/tokens.css`,
  `light-dark()` para temas. No estilos en línea salvo valores calculados.
- **Mensajes al usuario:** español venezolano, sin jerga técnica.
- **Commits:** una idea por commit, mensaje en presente ("Añade…", "Corrige…").
- **Ramas:** `main` protegida por revisión; trabajo en ramas cortas.
- **Secretos:** jamás en el repositorio ni en la documentación.

## 5. Recetas frecuentes

### Probar el flujo completo sin producción

```bash
cd ~/BLINK/simulacion
./arrancar.sh          # PostgreSQL + PostgREST + gateway + semilla
./flujo.sh             # lote → enrolado → registro → recarga → chip → cobro
./portal.sh            # interfaz del pasajero en :5175
./backoffice.sh        # panel en :5173 (otra terminal)
./detener.sh           # borra la base efímera
```

Si cambias una migración o un RPC, vuelve a ejecutar `./arrancar.sh && ./flujo.sh`
antes de commitear.

### Rotar la clave publishable

1. Panel de Supabase → Settings → API → regenerar la clave publishable.
2. Actualizar la variable `VITE_SUPABASE_ANON_KEY` del repositorio TARJETA.
3. Actualizar `.env.local` de POS.
4. Relanzar el workflow de Pages (push vacío o `workflow_dispatch`).

### Aprobar una recarga (mientras no hay UI)

```sql
select * from public.bt_recargas_pendientes(50);
select public.bt_aprobar_recarga('<uuid-de-recarga>', 'admin');
```

### Crear una cuenta de demostración en producción

No se recomienda sembrar cuentas en producción. Para demos, usar el modo local
del portal o crear la cuenta y eliminarla con:

```sql
delete from public.accounts where cedula_digitos = '<digitos>';
-- cards.account_id vuelve a NULL por "on delete set null"
```

### Reiniciar el segundo factor de un operador

Ver BLINK-DOC-06 §5.5. En resumen: `totp_secret = null, totp_activo = false` y
borrar sus sesiones; el panel vuelve a pedir la inscripción.

### Publicar una corrección urgente

```bash
npm run typecheck && npm test
git commit -am "Corrige …"
git push origin main          # TARJETA/BACKOFFICE publican solos
cd ~/BLINK/pos/pos/app && npm run deploy   # POS es manual
```

## 6. Lista de verificación antes de un PR

- [ ] `npm run typecheck` y `npm test` en verde.
- [ ] Migración probada en PostgreSQL local y en producción con rollback.
- [ ] Sin secretos en el diff (`git diff` revisado).
- [ ] Documentación y CHANGELOG actualizados.
- [ ] Flujo crítico probado en el navegador.
- [ ] Enlaces de documentos existentes (no dejar rutas rotas).

## 7. Dónde pedir contexto

| Tema | Fuente |
| --- | --- |
| Diseño técnico original | `~/BLINK/documentacion/fuentes/Documentación Técnica del Ecosistema Blink Pasajes.md` |
| Guía visual de la tarjeta | `~/BLINK/documentacion/fuentes/Guía de Implementación UI - Tarjeta Virtual Blink Pasajes.md` |
| Registro multi-tarjeta | `~/BLINK/documentacion/fuentes/Implementación de Registro y Gestión Multi-Tarjeta.md` |
| Estándares de hardware | `~/BLINK/documentacion/fuentes/Estándares_Industriales_y_Controles_de_Calidad_Adaptados_de_Tarjeta.md` |
| POS | `~/BLINK/pos/pos/app/README.md` y `~/BLINK/pos/documentos/` |
| Historial de cambios | `CHANGELOG.md` de cada repositorio |

Si un documento de `documentacion/fuentes` ya no existe, pídelo a quien mantenga
el proyecto: es la referencia de diseño y no debe reinventarse.
