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

delta_t(120).

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

shelf_max_weight("shelf_1", 50).  
shelf_max_weight("shelf_2", 50).
shelf_max_weight("shelf_3", 50).  
shelf_max_weight("shelf_4", 50).
shelf_max_weight("shelf_5", 100). 
shelf_max_weight("shelf_6", 100). 
shelf_max_weight("shelf_7", 100).
shelf_max_weight("shelf_8", 350). 
shelf_max_weight("shelf_9", 350).

/* ============================================================================
 * SELECCIÓN AUTÓNOMA DE ESTANTERÍA
 * Planes compartidos por los tres robots. Cada robot los incluye vía common.asl.
 * La selección se basa en el peso del contenedor, no en el tipo de robot.
 * ============================================================================ */

// ── Urgentes: solo van a estanterías urgentes (S1, S5, S8) ──────────────────
+!pick_shelf(CId, Weight, W, H) :
    claimed_type(CId, "urgent") & Weight <= 10 &
    shelf_category(ExS, light) & shelf_urgency(ExS, urgent) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, light, urgent).

+!pick_shelf(CId, Weight, W, H) :
    claimed_type(CId, "urgent") & Weight <= 30 &
    shelf_category(ExS, medium) & shelf_urgency(ExS, urgent) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, medium, urgent).

+!pick_shelf(CId, Weight, W, H) :
    claimed_type(CId, "urgent") &
    shelf_category(ExS, heavy) & shelf_urgency(ExS, urgent) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, heavy, urgent).

// Fallback urgente: respeta urgencia y categoría de tamaño
+!pick_shelf(CId, Weight, W, H) : claimed_type(CId, "urgent") <-
    .findall(pair(Occ, S), (shelf_urgency(S, urgent) & shelf_available(S) &
                             shelf_occupancy(S, Occ) & Occ < 85 &
                             not expansion_failed_shelf(CId, S) &
                             shelf_max_weight(S, MaxW) & Weight <= MaxW &
                             shelf_category(S, Cat) &
                             (Cat == heavy |
                              (Weight > 10 & Weight <= 30 & (Cat == medium | Cat == heavy)) |
                              Weight <= 10)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).

// ── No urgentes: solo van a estanterías no urgentes (S2-S4, S6-S7, S9) ──────
+!pick_shelf(CId, Weight, W, H) :
    Weight <= 10 &
    shelf_category(ExS, light) & shelf_urgency(ExS, non_urgent) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, light, non_urgent).

+!pick_shelf(CId, Weight, W, H) :
    Weight <= 30 &
    shelf_category(ExS, medium) & shelf_urgency(ExS, non_urgent) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, medium, non_urgent).

+!pick_shelf(CId, Weight, W, H) :
    shelf_category(ExS, heavy) & shelf_urgency(ExS, non_urgent) & shelf_available(ExS) <-
    !pick_least_occupied_shelf(CId, heavy, non_urgent).

// Fallback no urgente: respeta urgencia y categoría de tamaño
+!pick_shelf(CId, Weight, W, H) : shelf_available(_) <-
    .findall(pair(Occ, S), (shelf_urgency(S, non_urgent) & shelf_available(S) &
                             shelf_occupancy(S, Occ) & Occ < 85 &
                             not expansion_failed_shelf(CId, S) &
                             shelf_max_weight(S, MaxW) & Weight <= MaxW &
                             shelf_category(S, Cat) &
                             (Cat == heavy |
                              (Weight > 10 & Weight <= 30 & (Cat == medium | Cat == heavy)) |
                              Weight <= 10)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).

// Sin espacio: reintento con contador
-!pick_shelf(CId, Weight, W, H) : shelf_retries_count(CId, N) & N >= 3 <-
    .my_name(Me);
    .print("❌ [", Me, "] Sin estantería disponible para ", CId, ". Liberando.");
    .abolish(shelf_retries_count(CId, _));
    .abolish(claimed_type(CId, _));
    .abolish(expansion_failed_shelf(CId, _));
    +shelf_wait(CId);
    unclaim_container(CId);
    release_task(CId);
    -+carrying(none);
    .send(supervisor, tell, container_error(CId, no_shelf_space));
    !check_queue.

// Cooldown: impide re-reclamar el mismo contenedor durante 20s tras fallo de estantería
+shelf_wait(CId) <- .wait(20000); -shelf_wait(CId).
-container_at_entrance(CId, _, _, _, _) : shelf_wait(CId) <- -shelf_wait(CId).

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
 * RECLAMACIÓN Y SELECCIÓN DE ESTANTERÍA (compartido por todos los robots)
 * ============================================================================ */

+!try_claim(CId, Type, Weight, W, H) : state(idle) <-
    claim_container(CId);
    .send(supervisor, tell, container_claimed(CId, Type, Weight));
    +claimed_type(CId, Type);
    accept_task(CId);
    -+state(working);
    -+carrying(CId);
    !select_shelf_and_execute(CId, Weight, W, H).

-!try_claim(CId, Type, Weight, W, H) : true <- true.

+!select_shelf_and_execute(CId, Weight, W, H) : true <-
    !pick_shelf(CId, Weight, W, H);
    ?shelf_selected(CId, ShelfId);
    .abolish(shelf_selected(CId, _));
    .abolish(shelf_retries_count(CId, _));
    !execute_task(CId, ShelfId).

-!select_shelf_and_execute(CId, Weight, W, H) : true <-
    .my_name(Me);
    .print("⚠️ [", Me, "] Falló selección de estantería para ", CId);
    .abolish(claimed_type(CId, _));
    unclaim_container(CId);
    release_task(CId);
    -+carrying(none);
    !check_queue.

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
    .send(supervisor, tell, request_zone(Zone)); //ask??
    .wait(zone_granted(Zone));
    -zone_granted(Zone);
    +holding_zone(Zone).

+!release_zone(Zone) : holding_zone(Zone) <-
    -holding_zone(Zone);
    .send(supervisor, tell, release_zone(Zone)).

+!release_zone(Zone) : true <- true.

// Selecciona la estantería menos ocupada de una categoría y urgencia dadas (< 85%)
+!pick_least_occupied_shelf(CId, Cat, Urg) <-
    .findall(pair(Occ, S), (shelf_category(S, Cat) & shelf_urgency(S, Urg) &
                             shelf_available(S) & shelf_occupancy(S, Occ) & Occ < 85 &
                             not expansion_failed_shelf(CId, S)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).

/* ============================================================================
 * ENTREGA EN OUTBOUND
 * Si el robot ya está en una celda outbound (x=17-19, y=0-1), suelta
 * inmediatamente. Evita oscilación cuando el nav_target exacto está ocupado.
 * ============================================================================ */

// Going to left outbound/expansion/classification (TX < 5, TY < 2):
// approach at y=2 first to avoid crossing entrance (x=5-7) and classification (x=3-4) zones at y=0-1.
// Guard X > TX ensures no recursion when robot is already in the target column.
+!navigate(TX, TY) : TX < 5 & TY < 2 & robot_pos(X, Y) & Y > 1 & X > TX <-
    !navigate(TX, 2);
    !navigate(TX, TY).

// At x=17-18 heading to outbound but blocked by y=2-3 shelf cells (S4 at x=16-17):
// step to x=19 first (free column), then descend into zone.
+!navigate(TX, TY) : TX >= 17 & TY < 2 & robot_pos(X, Y) & X >= 17 & X < 19 & Y >= 2 <-
    !navigate(19, Y);
    !navigate(TX, TY).

// At x=19, y>=2, heading to right outbound: descend x=19 column into zone.
// TX\==19 guard prevents recursion when inner !navigate(19,1) re-evaluates this plan.
+!navigate(TX, TY) : TX >= 17 & TY < 2 & TX \== 19 & robot_pos(X, Y) & X == 19 & Y >= 2 <-
    !navigate(19, 1);
    !navigate(TX, TY).

+!drop_at_outbound(CId) <-
    !acquire_zone(outbound);
    move_to_outbound;
    ?nav_target(TX, TY);
    !navigate(TX, TY);
    drop_in_outbound(CId);
    !release_zone(outbound).

-!drop_at_outbound(CId) <-
    !release_zone(outbound);
    .wait(1500);
    !drop_at_outbound(CId).
