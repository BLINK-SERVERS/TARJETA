# Guía para retomar el desarrollo

| Campo | Valor |
| --- | --- |
| Código | BLINK-DOC-10 |
| Versión | 1.3.0 |
| Fecha | 2026-10-30 |
| Estado | Vigente |
| Norma | ISO/IEC/IEEE 26515 |

## 1. En diez minutos

1. Lee el [índice](README.md) y la [arquitectura](02-arquitectura.md).
2. Clona los cuatro repositorios de la organización `BLINK-SERVERS`:
   `TARJETA`, `PASAJES`, `BACKOFFICE` y `POS`.
3. Instala Node 22+, `gh` y `psql`; autentica con `gh auth login`.
4. Ejecuta `npm ci && npm test` en cada repositorio.
5. TARJETA sin `.env.local` funciona en **modo demostración**; para la nube pide
   las variables a quien administre el proyecto Supabase.
6. Para tocar la base, pide la contraseña al gestor de secretos (nunca por chat).

## 2. Mapa mental

```text
BLINK_Tarjeta/                     ← portal del pasajero + esquema compartido
  src/pages/                       Acceso, Inicio, Movimientos, Recargar, Perfil
  src/lib/repo.ts                  selector nube/local
  src/lib/nube.ts                  cliente RPC (contrato en BLINK-DOC-04)
  src/lib/local.ts                 espejo local del contrato
  src/components/TarjetaVirtual.tsx tarjeta ID-1 con giro 3D
  src/styles/app.css               tarjeta con container queries (cqw)
  supabase/migrations/             0001…0009 (0007 back-office + TOTP, 0008 lectura, 0009 serie de 7 dígitos y maestra)
  scripts/lote.ts                  generación de lotes y hoja de impresión
  docs/                            esta suite

BLINK_Backoffice/                  ← consola administrativa (rol ADMIN/TAQUILLA + TOTP)
  src/lib/api.ts                   cliente RPC con token de sesión (BLINK-DOC-04 §4)
  src/lib/serial.ts                lector ESP32 por Web Serial
  src/pages/Acceso.tsx, Mfa.tsx    login cédula+PIN y alta del segundo factor
  src/pages/Lotes.tsx              creación de lotes y exportación CSV
  src/pages/Inventario.tsx         filtros por lote, serial y estado
  src/pages/Estacion.tsx           captura UID y carga masiva
  src/pages/Taquilla.tsx           asignación serial ↔ cédula

BLINK_Pasajes_Project/app/         ← panel de la línea (local + Web Serial)
  src/pages/Lector.tsx             puente serie con el lector ESP32
  src/pages/Fiscal.tsx             reporte fiscal
  src/pages/Admin.tsx              aprobación y liquidación (local)
  src/pages/Pasajero.tsx           flujo de recarga guiado
  src/lib/serial.ts                protocolo READY/CARD/PONG
  scripts/configurar-dominio.mjs   dominio + HTTPS vía API de GitHub

BLINK_POS_Project/app/             ← comercio (Supabase Auth + RLS)
  src/lib/cloud.ts                 autenticación y persistencia
  src/lib/store.tsx                estado global
  README.md                        documentación extensa de POS
```

Firmware (fuera de git): `~/Arduino/BLINK_Lector` y `~/Arduino/BLINK_Validador`.

## 3. Cómo añadir una función al portal

1. **Base de datos:** nueva migración `0010_*.sql` con la función
   `bt_*` (`security definer`, `search_path` fijo) y sus `revoke`/`grant`.
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
git push origin main          # TARJETA/PASAJES/BACKOFFICE publican solos
cd BLINK_POS_Project/app && npm run deploy   # POS es manual
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
| Diseño técnico original | `~/Descargas/Documentación Técnica del Ecosistema Blink Pasajes.md` |
| Guía visual de la tarjeta | `~/Descargas/Guía de Implementación UI - Tarjeta Virtual Blink Pasajes.md` |
| Registro multi-tarjeta | `~/Descargas/Implementación de Registro y Gestión Multi-Tarjeta.md` |
| POS | `BLINK_POS_Project/app/README.md` y `~/BLINK_POS_Documentos/` |
| Historial de cambios | `CHANGELOG.md` de cada repositorio |

Si un documento de Descargas ya no existe, pídelo a quien mantenga el proyecto: es
la referencia de diseño y no debe reinventarse.
