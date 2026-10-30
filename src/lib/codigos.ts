// Códigos imprimibles del reverso de la tarjeta.
//
// El QR es fijo (abre el portal) y vive en `public/qr-portal.svg`, generado
// una sola vez con bwip-js. El Code 128 lleva el serial de cada tarjeta y se
// arma aquí con su tabla de patrones: así el teléfono no descarga los 900 KB
// de bwip-js solo para pintar las barras.

import { soloDigitos } from "./formato";

export const QR_PORTAL = `${import.meta.env.BASE_URL}qr-portal.svg`;

const QUIETO = 10;
const ALTO_BARRA = 40;
const INICIO_C = 105;
const CAMBIO_B = 100;
const FIN = 106;

// Anchuras de barra/espacio (en módulos) de los 106 símbolos Code 128.
// El símbolo de parada tiene siete elementos y se guarda aparte.
const PATRONES = `
212222 222122 222221 121223 121322 131222 122213 122312 132212 221213
221312 231212 112232 122132 122231 113222 123122 123221 223211 221132
221231 213212 223112 312131 311222 321122 321221 312212 322112 322211
212123 212321 232121 111323 131123 131321 112313 132113 132311 211313
231113 231311 112133 112331 132131 113123 113321 133121 313121 211331
231131 213113 213311 213131 311123 311321 331121 312113 312311 332111
314111 221411 431111 111224 111422 121124 121421 141122 141221 112214
112412 122114 122411 142112 142211 241211 221114 413111 241112 134111
111242 121142 121241 114212 124112 124211 411212 421112 421211 212141
214121 412121 111143 111341 131141 114113 114311 411113 411311 113141
114131 311141 411131 211412 211214 211232
`.trim().split(/\s+/);

const PATRON_FIN = "2331112";

/**
 * Code 128 del serial. Los pares van en el juego C (compacto) y, si el
 * número de dígitos es impar —el serial de 11 dígitos de la serie nueva—,
 * el último dígito se codifica en el juego B tras un cambio. Agrega el
 * verificador módulo 103 y la parada. El SVG sale ya vertical (barras
 * horizontales) para la franja del reverso.
 */
export function svgCode128(serial: string): string | null {
  const digitos = soloDigitos(serial);
  if (digitos.length === 0) return null;

  const valores = [INICIO_C];
  const pares = digitos.length - (digitos.length % 2);
  for (let i = 0; i < pares; i += 2) {
    valores.push(Number(digitos.slice(i, i + 2)));
  }
  if (digitos.length % 2 === 1) {
    // Juego B: el valor de un dígito ASCII es su código menos 32.
    valores.push(CAMBIO_B, digitos.charCodeAt(digitos.length - 1) - 32);
  }
  const suma = valores.reduce((total, valor, indice) => total + valor * Math.max(indice, 1), 0);
  const secuencia = [...valores, suma % 103, FIN];

  let y = QUIETO;
  const barras: string[] = [];
  for (const valor of secuencia) {
    const anchos = (valor === FIN ? PATRON_FIN : PATRONES[valor]).split("").map(Number);
    for (let i = 0; i < anchos.length; i++) {
      if (i % 2 === 0) {
        barras.push(`<rect x="0" y="${y}" width="${ALTO_BARRA}" height="${anchos[i]}"/>`);
      }
      y += anchos[i];
    }
  }

  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${ALTO_BARRA} ${y + QUIETO}" ` +
    `shape-rendering="crispEdges">${barras.join("")}</svg>`;
  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}
