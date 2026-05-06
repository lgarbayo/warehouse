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
    .print("[TRANSPORT] Agente de transporte iniciado.").

+transport_request(ContainerType, Phase)[source(_)] <-
    .my_name(Me);
    .time(H, M, S); T = H * 3600 + M * 60 + S;
    .print("[TRANSPORT] Camión despachado: tipo=", ContainerType, " fase=", Phase, " T=", T);
    .print("EVENT | time=", T, " | agent=transport | type=transport_dispatched | data=", ContainerType).
