// Recorre el ciclo completo de BLINK TARJETA contra la base local:
// lote y enrolado (back-office) → registro → reclamo → recarga → aprobación
// del operador → sincronización del validador → entrega al chip → cobro.
// No usa el proyecto de Supabase de producción.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { Client } from "pg";

const entorno = JSON.parse(
  readFileSync(new URL("./.entorno", import.meta.url), "utf8"),
);

const db = new Client({ connectionString: entorno.baseDatos });
await db.connect();

const paso = (n, texto) => console.log(`\n[${n}] ${texto}`);
const ok = (texto) => console.log(`    ✓ ${texto}`);

async function rpc(nombre, argumentos = {}, llave = entorno.anonKey) {
  const respuesta = await fetch(`${entorno.url}/rest/v1/rpc/${nombre}`, {
    method: "POST",
    headers: {
      apikey: llave,
      Authorization: `Bearer ${llave}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(argumentos),
  });
  const texto = await respuesta.text();
  const dato = texto ? JSON.parse(texto) : null;
  if (!respuesta.ok) {
    throw new Error(`${nombre}: ${dato?.message ?? respuesta.status}`);
  }
  return dato;
}

async function servicio(texto, valores = []) {
  await db.query("begin");
  try {
    await db.query("set local role service_role");
    const resultado = await db.query(texto, valores);
    await db.query("commit");
    return resultado.rows;
  } catch (error) {
    await db.query("rollback");
    throw error;
  }
}

try {
  paso(1, "Back-office: lote de 2 tarjetas y enrolado del chip");
  const [loteFila] = await servicio(
    "select public.bt_generar_lote($1, $2, $3, $4, $5) as r",
    [2, "Simulación", 23, 1, "ESTACION"],
  );
  const lote = loteFila.r;
  const seriales = lote.tarjetas.map((t) => t.serial);
  ok(`lote ${lote.lote.numero}: ${seriales.join(", ")}`);

  const uids = ["04A1B2C3D4E5F6", "04F6E5D4C3B2A1"];
  const [enroladoFila] = await servicio(
    "select public.bt_estacion_enrolar($1, $2::jsonb, $3) as r",
    [
      lote.lote.id,
      JSON.stringify(seriales.map((serial, i) => ({ serial, uid: uids[i] }))),
      "Estación Simulación",
    ],
  );
  assert.equal(enroladoFila.r.rechazadas, 0, "el enrolado no debe rechazar tarjetas");
  ok(`enroladas ${enroladoFila.r.enroladas} tarjetas`);

  paso(2, "Pasajera: registro y reclamo de la primera tarjeta");
  const registro = await rpc("bt_registrar", {
    p_nombres: "Ana",
    p_apellidos: "Simulación",
    p_cedula: "V-20123456",
    p_telefono: "04141234567",
    p_correo: "ana@blink.local",
    p_pin: "258036",
  });
  const token = registro.token;
  assert.ok(token, "el registro debe devolver token");
  ok(`cuenta creada (${registro.cuenta?.nombre ?? "Ana Simulación"})`);

  const reclamo = await rpc("bt_vincular", {
    p_token: token,
    p_serial: seriales[0],
  });
  assert.equal(reclamo.tarjetas.length, 1, "debe quedar una tarjeta en la billetera");
  ok(`tarjeta ${seriales[0]} activa con saldo ${reclamo.tarjetas[0].saldo} Bs`);

  paso(3, "Pasajera: reporta el Pago Móvil de 1.000 Bs");
  const recarga = await rpc("bt_recargar", {
    p_token: token,
    p_serial: seriales[0],
    p_monto: 1000,
    p_telefono: "04141234567",
    p_banco: "Banesco",
    p_referencia: "4821",
  });
  assert.equal(recarga.movimiento.estado, "pendiente");
  ok(`movimiento ${recarga.movimiento.estado}: «${recarga.movimiento.detalle}»`);

  paso(4, "Operador: bandeja de recargas pendientes");
  const [bandejaFila] = await servicio(
    "select public.bt_recargas_pendientes(10) as r",
  );
  const pendiente = bandejaFila.r.recargas[0];
  assert.equal(pendiente.monto, 1000);
  assert.equal(pendiente.referencia, "4821");
  ok(`${bandejaFila.r.recargas.length} pendiente(s): ${pendiente.serial} · ${pendiente.banco} · ref ${pendiente.referencia}`);

  paso(5, "Operador: aprueba la recarga");
  const [aprobadaFila] = await servicio(
    "select public.bt_aprobar_recarga($1, $2) as r",
    [pendiente.recarga, "Operador Simulación"],
  );
  assert.equal(aprobadaFila.r.ok, true);
  assert.equal(Number(aprobadaFila.r.saldo), 1000);
  ok(`saldo virtual acreditado: ${aprobadaFila.r.saldo} Bs`);

  paso(6, "Validador: token del equipo y descarga de recargas aprobadas");
  const [tokenFila] = await servicio(
    "select public.bt_validador_emitir_token($1) as r",
    ["A0B1C2D3E4F5"],
  );
  const tokenValidador = tokenFila.r.token;
  const sync1 = await rpc("bt_validador_sincronizar_token", {
    p_token: tokenValidador,
  });
  const descargada = sync1.pendientes.find((p) => p.id === pendiente.recarga);
  assert.ok(descargada, "la recarga aprobada debe bajar al validador");
  ok(`descargada ${descargada.serial} por ${descargada.monto} Bs`);

  paso(7, "Chip: aplica la recarga y cobra el pasaje");
  const offlineId = `sim-${Date.now()}`;
  console.log(
    `    · RECARGA_APLICADA,serial=${descargada.serial},monto=${descargada.monto},id=${descargada.id}`,
  );
  const sync2 = await rpc("bt_validador_sincronizar_token", {
    p_token: tokenValidador,
    p_taps: [
      {
        offline_id: offlineId,
        visible_id: descargada.serial,
        fare_charged: 500,
        fare_type: 1,
        chip_balance_after: 500,
        tapped_at: new Date().toISOString(),
      },
    ],
    p_recargas: [{ id: descargada.id }],
  });
  assert.equal(sync2.procesadas, 1, "el toque debe procesarse");
  assert.equal(sync2.rechazadas.length, 0);
  assert.equal(sync2.pendientes.length, 0, "no deben quedar recargas sin bajar");
  ok("viaje de 500 Bs registrado y recarga marcada como entregada");

  paso(8, "Verificación en la base y en el portal");
  const { rows: tarjetas } = await db.query(
    "select virtual_balance, last_chip_balance from public.cards where visible_id = $1",
    [seriales[0]],
  );
  assert.equal(Number(tarjetas[0].virtual_balance), 500);
  const { rows: recargas } = await db.query(
    "select status, synced_to_chip from public.recharges where id = $1",
    [pendiente.recarga],
  );
  assert.equal(recargas[0].status, "aprobado");
  assert.equal(recargas[0].synced_to_chip, true);
  ok("saldo virtual 500 Bs · recarga aprobada y entregada al chip");

  const movimientos = await rpc("bt_movimientos", {
    p_token: token,
    p_serial: seriales[0],
    p_limite: 20,
  });
  const lista = movimientos.movimientos;
  assert.ok(
    lista.some((m) => m.detalle === "Pago Móvil aprobado" && m.estado === "aprobado"),
  );
  assert.ok(lista.some((m) => m.tipo === "viaje" && Number(m.monto) === -500));
  ok(`portal: ${lista.length} movimientos (recarga aprobada + viaje)`);

  paso(9, "Rechazo y regla de duplicado");
  await rpc("bt_vincular", { p_token: token, p_serial: seriales[1] });
  await rpc("bt_recargar", {
    p_token: token,
    p_serial: seriales[1],
    p_monto: 300,
    p_telefono: "04141234567",
    p_banco: "Mercantil",
    p_referencia: "7777",
  });
  const [bandeja2Fila] = await servicio(
    "select public.bt_recargas_pendientes(10) as r",
  );
  const porRechazar = bandeja2Fila.r.recargas.find(
    (r) => r.serial === seriales[1] && r.monto === 300,
  );
  assert.ok(porRechazar, "la recarga de la segunda tarjeta debe estar pendiente");
  const [rechazadaFila] = await servicio(
    "select public.bt_rechazar_recarga($1, $2, $3) as r",
    [porRechazar.recarga, "Operador Simulación", "Referencia no coincide"],
  );
  assert.equal(rechazadaFila.r.ok, true);
  const { rows: segunda } = await db.query(
    "select virtual_balance from public.cards where visible_id = $1",
    [seriales[1]],
  );
  assert.equal(Number(segunda[0].virtual_balance), 0, "un rechazo no acredita saldo");
  ok("recarga rechazada sin tocar el saldo");

  let duplicado = null;
  try {
    await rpc("bt_recargar", {
      p_token: token,
      p_serial: seriales[0],
      p_monto: 1000,
      p_telefono: "04141234567",
      p_banco: "Banesco",
      p_referencia: "4821",
    });
  } catch (error) {
    duplicado = error.message;
  }
  assert.match(duplicado ?? "", /bt:duplicada/);
  ok("la misma referencia otra vez se rechaza (bt:duplicada)");

  paso(10, "Resumen operativo");
  const [resumenFila] = await servicio(
    "select public.bt_resumen_operativo() as r",
  );
  console.log(JSON.stringify(resumenFila.r, null, 2));

  console.log("\nFlujo completo simulado sin errores.");
} catch (error) {
  console.error(`\n✗ ${error.message}`);
  process.exitCode = 1;
} finally {
  await db.end();
}
