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

delta_t(30).

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

shelf_category("shelf_1", light).
shelf_category("shelf_2", light).
shelf_category("shelf_3", light).
shelf_category("shelf_4", light).
shelf_category("shelf_5", medium).
shelf_category("shelf_6", medium).
shelf_category("shelf_7", medium).
shelf_category("shelf_8", heavy).
shelf_category("shelf_9", heavy).

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

// Fallback: cualquier estantería disponible < 85%
+!pick_shelf(CId, Weight, W, H) : shelf_available(_) <-
    .findall(pair(Occ, S), (shelf_available(S) & shelf_occupancy(S, Occ) & Occ < 85 & not expansion_failed_shelf(CId, S)), Pairs);
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

// Selecciona la estantería menos ocupada de una categoría dada (< 85%)
+!pick_least_occupied_shelf(CId, Cat) <-
    .findall(pair(Occ, S), (shelf_category(S, Cat) & shelf_available(S) & shelf_occupancy(S, Occ) & Occ < 85 & not expansion_failed_shelf(CId, S)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).
