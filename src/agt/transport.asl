/*******************************************************************************
 * TRANSPORT - Agente de Transporte
 *
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 *
 * Simula la llegada de camiones para recoger contenedores de la zona OUTBOUND
 * al finalizar cada deadline del ciclo de salida.
 ******************************************************************************/

{ include("common.asl") }

!start.

/* Estrategia de recogida dual:
 *   1. Periódica (cada 30s): evita que los contenedores se acumulen indefinidamente
 *      en la zona outbound si el ciclo de salida no llena el outbound completamente.
 *   2. Reactiva (outbound_full): el entorno emite outbound_full cuando move_to_outbound
 *      no encuentra ninguna celda libre. El camión llega inmediatamente para desbloquear
 *      a los robots antes del timeout de nav_failed (20s).
 *   3. Por demanda (transport_request): el scheduler avisa al finalizar cada deadline
 *      para recoger los contenedores acumulados durante la fase y liberar el outbound
 *      para el siguiente ciclo.
 */

+!start : true <-
    .print("[TRANSPORT] Agente de transporte iniciado.");
    !periodic_collect_loop.

// Recogida periódica de seguridad: garantiza que ningún contenedor quede abandonado
// en el outbound aunque no se haya llenado del todo durante un ciclo de salida.
+!periodic_collect_loop : true <-
    .wait(30000);
    collect_outbound_containers;
    !periodic_collect_loop.

// Recogida reactiva urgente: outbound lleno → el camión llega inmediatamente.
// Esto desbloquea a los robots que esperan drop_in_outbound antes del timeout de 20s.
+outbound_full <-
    .time(H, M, S); T = H * 3600 + M * 60 + S;
    .print("EVENT | time=", T, " | agent=transport | type=transport_dispatched | data=outbound_full");
    collect_outbound_containers;
    -outbound_full.

// Recogida por fin de fase: el scheduler notifica al finalizar cada deadline para
// vaciar el outbound y prepararlo para el siguiente ciclo de salida.
+transport_request(ContainerType, Phase)[source(_)] <-
    .time(H, M, S); T = H * 3600 + M * 60 + S;
    .print("EVENT | time=", T, " | agent=transport | type=transport_dispatched | data=", ContainerType);
    collect_outbound_containers.
