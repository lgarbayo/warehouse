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

+!start : true <-
    .print("[TRANSPORT] Agente de transporte iniciado.");
    !periodic_collect_loop.

+!periodic_collect_loop : true <-
    .wait(30000);
    collect_outbound_containers;
    !periodic_collect_loop.

// Limpieza reactiva: Java emite outbound_full cuando move_to_outbound no encuentra
// celda libre. El camión llega inmediatamente en lugar de esperar el fin de fase.
+outbound_full <-
    .time(H, M, S); T = H * 3600 + M * 60 + S;
    .print("EVENT | time=", T, " | agent=transport | type=transport_dispatched | data=outbound_full");
    collect_outbound_containers;
    -outbound_full.

// Limpieza al finalizar cada fase del ciclo de salida.
+transport_request(ContainerType, Phase)[source(_)] <-
    .time(H, M, S); T = H * 3600 + M * 60 + S;
    .print("EVENT | time=", T, " | agent=transport | type=transport_dispatched | data=", ContainerType);
    collect_outbound_containers.
