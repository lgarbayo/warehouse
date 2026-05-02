/*******************************************************************************
 * COMMON - Constantes y clasificaciones globales del sistema
 *
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 *
 * Incluir en todos los agentes con: { include("common.asl") }
 ******************************************************************************/

/* ============================================================================
 * TEMPORIZACIÓN
 * ============================================================================ */

delta_t(60).

/* ============================================================================
 * CLASIFICACIÓN DE TIPOS DE CONTENEDOR
 * ============================================================================ */

urgent_container_type("urgent").
non_urgent_container_type("standard").
non_urgent_container_type("fragile").

/* ============================================================================
 * CATEGORÍAS DE ESTANTERÍAS
 * Compartidas por robots y scheduler para selección autónoma de estanterías.
 * ============================================================================ */

shelf_urgency("shelf_1", urgent).
shelf_urgency("shelf_5", urgent).
shelf_urgency("shelf_8", urgent).
shelf_urgency("shelf_2", non_urgent).
shelf_urgency("shelf_3", non_urgent).
shelf_urgency("shelf_4", non_urgent).
shelf_urgency("shelf_6", non_urgent).
shelf_urgency("shelf_7", non_urgent).
shelf_urgency("shelf_9", non_urgent).

shelf_category("shelf_1", light).
shelf_category("shelf_2", light).
shelf_category("shelf_3", light).
shelf_category("shelf_4", light).
shelf_category("shelf_5", medium).
shelf_category("shelf_6", medium).
shelf_category("shelf_7", medium).
shelf_category("shelf_8", heavy).
shelf_category("shelf_9", heavy).

shelf_max_weight("shelf_1", 50).  shelf_max_weight("shelf_2", 50).
shelf_max_weight("shelf_3", 50).  shelf_max_weight("shelf_4", 50).
shelf_max_weight("shelf_5", 100). shelf_max_weight("shelf_6", 100). shelf_max_weight("shelf_7", 100).
shelf_max_weight("shelf_8", 350). shelf_max_weight("shelf_9", 350).

/* ============================================================================
 * SELECCIÓN AUTÓNOMA DE ESTANTERÍA
 * Planes compartidos por los tres robots. Cada robot los incluye vía common.asl.
 * La selección se basa en el peso del contenedor, no en el tipo de robot.
 * ============================================================================ */

// Contenedor ligero → estantería pequeña
+!pick_shelf(CId, Weight, W, H) :
    Weight <= 10 & shelf_category(ExS, light) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, light).

// Contenedor mediano → estantería mediana
+!pick_shelf(CId, Weight, W, H) :
    Weight <= 30 & shelf_category(ExS, medium) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, medium).

// Contenedor pesado → estantería grande
+!pick_shelf(CId, Weight, W, H) :
    shelf_category(ExS, heavy) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, heavy).

// Fallback: cualquier estantería disponible < 85% que aguante el peso
+!pick_shelf(CId, Weight, W, H) : shelf_available(_) <-
    .findall(pair(Occ, S), (shelf_available(S) & shelf_occupancy(S, Occ) & Occ < 85
                             & not expansion_failed_shelf(CId, S)
                             & shelf_max_weight(S, MaxW) & Weight <= MaxW), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).

// Sin espacio: reintento con contador
-!pick_shelf(CId, Weight, W, H) : shelf_retries_count(CId, N) & N >= 3 <-
    .my_name(Me);
    .print("❌ [", Me, "] Sin estantería disponible para ", CId, ". Liberando.");
    .abolish(shelf_retries_count(CId, _));
    .abolish(claimed_type(CId, _));
    .abolish(expansion_failed_shelf(CId, _));
    unclaim_container(CId);
    release_task(CId);
    -+carrying(none);
    .send(supervisor, tell, container_error(CId, no_shelf_space));
    !check_queue.

-!pick_shelf(CId, Weight, W, H) : shelf_retries_count(CId, N) <-
    N1 = N + 1;
    -shelf_retries_count(CId, _);
    +shelf_retries_count(CId, N1);
    .print("⚠️ Sin estantería para ", CId, ". Reintento ", N1, "/3...");
    .wait(5000);
    !pick_shelf(CId, Weight, W, H).

-!pick_shelf(CId, Weight, W, H) : true <-
    +shelf_retries_count(CId, 1);
    .print("⚠️ Sin estantería para ", CId, ". Reintento 1/3...");
    .wait(5000);
    !pick_shelf(CId, Weight, W, H).

/* ============================================================================
 * EXPANSION DROP CON REINTENTO
 * ============================================================================ */

+!safe_expand_drop(CId) <-
    !acquire_zone(expansion);
    -nav_limit(_); +nav_limit(200);
    move_to_expansion;
    ?nav_target(TX, TY);
    !navigate(TX, TY);
    drop_in_expansion(CId);
    !release_zone(expansion);
    .abolish(expand_drop_retries(CId, _)).

-!safe_expand_drop(CId) : expand_drop_retries(CId, N) & N >= 2 <-
    .my_name(Me);
    .print("❌ [", Me, "] Expansión bloqueada para ", CId, ". Descartando.");
    .abolish(expand_drop_retries(CId, _));
    !release_zone(expansion);
    discard_container(CId).

-!safe_expand_drop(CId) : expand_drop_retries(CId, N) <-
    N1 = N + 1;
    -expand_drop_retries(CId, _);
    +expand_drop_retries(CId, N1);
    !release_zone(expansion);
    .wait(2000);
    !safe_expand_drop(CId).

-!safe_expand_drop(CId) <-
    +expand_drop_retries(CId, 1);
    !release_zone(expansion);
    .wait(2000);
    !safe_expand_drop(CId).

/* ============================================================================
 * MUTEX DE ZONA
 * ============================================================================ */

+!acquire_zone(Zone) : holding_zone(Zone) <- true.

+!acquire_zone(Zone) <-
    -zone_granted(Zone);
    .send(supervisor, tell, request_zone(Zone));
    .wait(zone_granted(Zone));
    -zone_granted(Zone);
    +holding_zone(Zone).

+!release_zone(Zone) : holding_zone(Zone) <-
    -holding_zone(Zone);
    .send(supervisor, tell, release_zone(Zone)).

+!release_zone(Zone) : true <- true.

// Selecciona la estantería menos ocupada de una categoría dada (< 85%)
+!pick_least_occupied_shelf(CId, Cat) <-
    .findall(pair(Occ, S), (shelf_category(S, Cat) & shelf_available(S) & shelf_occupancy(S, Occ) & Occ < 85 & not expansion_failed_shelf(CId, S)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).
