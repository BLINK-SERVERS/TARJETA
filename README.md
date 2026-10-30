# BLINK TARJETA

Portal del pasajero para consultar, vincular y recargar la tarjeta de transporte
de **BLINK PASAJES**. React 19 + Vite 8 + TypeScript estricto.

- **Sitio publicado:** https://blink-servers.github.io/TARJETA/
- **Panel de la línea:** https://pasajes.blink.com.ve/
- **Comercio:** https://www.blink.com.ve/
- **Versión:** 1.0.0 · [CHANGELOG](CHANGELOG.md)

## Qué hace

- Registro de cuenta con cédula, teléfono, correo, PIN de 6 dígitos y fuente de
  Pago Móvil (propia o de un familiar).
- Billetera con **varias tarjetas** por cuenta, vinculadas por el serial del reverso.
- Saldo, movimientos, tarjeta virtual con giro 3D y código de barras Code 128.
- Recarga reportada por Pago Móvil con comprobante en revisión.
- Cambio de PIN y de datos de pago.

Sin variables de entorno la app funciona en **modo demostración** con datos
locales (`V-12345678` / PIN `194628`). Con variables, usa la base real.

## Puesta en marcha

```bash
npm ci
npm run dev        # http://localhost:5173
npm run typecheck
npm test           # 60 pruebas
npm run build
npm run lote       # genera un lote de seriales y la hoja de impresión
```

Variables para conectar la nube (en `.env.local`, nunca en git):

```dotenv
VITE_SUPABASE_URL=https://<ref>.supabase.co
VITE_SUPABASE_ANON_KEY=<clave publishable>
```

## Estructura

```text
src/
  pages/            Acceso, Inicio, Movimientos, Recargar, Perfil
  components/       TarjetaVirtual, HojaVincular, PinEntrada, BarraTabs…
  lib/
    repo.ts         elige nube o local
    nube.ts         cliente de los RPC bt_*
    local.ts        espejo local del mismo contrato
    dominio.ts      validaciones de cédula, teléfono, serial, montos
  styles/           tokens, base y BEM de la app (tarjeta con cqw)
supabase/migrations/ 0001…0005 (esquema compartido del ecosistema)
scripts/lote.ts      generador de lotes y hoja imprimible
docs/                documentación ISO del ecosistema
```

## Despliegue

Cada push a `main` dispara `.github/workflows/pages.yml`: `typecheck` → `test` →
`build --base=/TARJETA/` → GitHub Pages. Si falla un paso, no se publica.

## Documentación

| Documento | Contenido |
| --- | --- |
| [docs/README.md](docs/README.md) | Índice y control documental (ISO 9001 / 12207). |
| [docs/02-arquitectura.md](docs/02-arquitectura.md) | Componentes, flujos y decisiones. |
| [docs/03-modelo-de-datos.md](docs/03-modelo-de-datos.md) | Tablas, migraciones y reglas. |
| [docs/04-api-rpc.md](docs/04-api-rpc.md) | Contrato de las funciones RPC. |
| [docs/06-operacion-y-despliegue.md](docs/06-operacion-y-despliegue.md) | Despliegue, DNS, base de datos y firmware. |
| [docs/07-pruebas-y-calidad.md](docs/07-pruebas-y-calidad.md) | Estrategia y resultados. |
| [docs/08-manual-de-usuario.md](docs/08-manual-de-usuario.md) | Guía del pasajero, chofer y comercio. |
| [docs/10-guia-de-retoma.md](docs/10-guia-de-retoma.md) | Cómo continuar el desarrollo. |

## Base de datos compartida

BLINK TARJETA, BLINK PASAJES y BLINK POS usan el mismo proyecto de Supabase.
El esquema de transporte vive en `supabase/migrations/` dentro de este
repositorio y es la **fuente de verdad**; cualquier cambio debe probarse contra
las tres aplicaciones antes de publicarse.
