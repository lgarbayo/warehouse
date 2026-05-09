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

// ΔT = 120s: tiempo máximo por fase del ciclo de salida.
// Justificación: un robot heavy (velocidad 1, 1 celda/paso) desde shelf_9
// (x≈18, y≈10) hasta outbound (x=0-2, y=0-1) recorre ~26 celdas.
// Con backoffs y congestión de navegación el tiempo real puede ser 2-3x,
// llegando a ~90-100s. 120s da margen suficiente para el peor caso.
// Fase urgente: [T0, T0+ΔT). Fase no urgente: [T0+ΔT, T0+3·ΔT).
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
 * Planes compartidos por los 4 robots. Cada robot los incluye vía common.asl.
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
        shelf_occupancy(S, Occ) & Occ < 85 & not expansion_failed_shelf(CId, S) &
        shelf_max_weight(S, MaxW) & Weight <= MaxW & shelf_category(S, Cat) &
        (Cat == heavy | (Weight > 10 & Weight <= 30 & (Cat == medium | Cat == heavy)) |
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
        shelf_occupancy(S, Occ) & Occ < 85 & not expansion_failed_shelf(CId, S) &
        shelf_max_weight(S, MaxW) & Weight <= MaxW & shelf_category(S, Cat) &
        (Cat == heavy | (Weight > 10 & Weight <= 30 & (Cat == medium | Cat == heavy)) |
        Weight <= 10)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).

// Sin espacio tras 1 reintento: notificar y propagar fallo.
// El cleanup (unclaim, release, check_queue) lo hace -!select_shelf_and_execute.
// El robot retiene el container durante el reintento (3s) → la celda de entrada
// no se libera, evitando congestión en la zona inbound cuando varios robots fallan
// a la vez. blocked_type llega en <1s, así que el reintento ya lo ve activo.
-!pick_shelf(CId, Weight, W, H) : shelf_retried(CId) <-
    .my_name(Me);
    .print("❌ [", Me, "] Sin estantería disponible para ", CId, ". Liberando.");
    -shelf_retried(CId);
    .abolish(expansion_failed_shelf(CId, _));
    +shelf_wait(CId);
    .send(supervisor, tell, container_error(CId, no_shelf_space));
    .fail.

-!pick_shelf(CId, Weight, W, H) : true <-
    +shelf_retried(CId);
    .print("⚠️ Sin estantería para ", CId, ". Reintento en 3s...");
    .wait(3000);
    !pick_shelf(CId, Weight, W, H).

// Cooldown de 5s: margen para que blocked_type se propague desde supervisor →
// scheduler → robots antes de que container_at_entrance re-dispare el claim.
+shelf_wait(CId) <- .wait(5000); -shelf_wait(CId).

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
    .abolish(shelf_retried(CId));
    !execute_task(CId, ShelfId).

-!select_shelf_and_execute(CId, Weight, W, H) : true <-
    .my_name(Me);
    .print("⚠️ [", Me, "] Falló selección de estantería para ", CId);
    .abolish(claimed_type(CId, _));
    .abolish(expansion_failed_shelf(CId, _));
    -+carrying(none);
    unclaim_container(CId);
    release_task(CId);
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

// Si el robot ya tiene la zona (p.ej. re-intento tras fallo), no la pide de nuevo.
+!acquire_zone(Zone) : holding_zone(Zone) <- true.

+!acquire_zone(Zone) <-
    -zone_granted(Zone);
    .send(supervisor, tell, request_zone(Zone));
    // .wait/1 con un literal de creencia suspende la intención hasta que esa creencia
    // aparezca en la base — es el patrón Jason de bloqueo sin polling activo.
    .wait(zone_granted(Zone));
    -zone_granted(Zone);
    +holding_zone(Zone).

+!release_zone(Zone) : holding_zone(Zone) <-
    -holding_zone(Zone);
    .send(supervisor, tell, release_zone(Zone)).

// Idempotente: si el robot no tenía la zona (p.ej. fallo antes de acquire), no falla.
+!release_zone(Zone) : true <- true.

// Heurística greedy: elige la estantería menos ocupada de la categoría y urgencia
// correctas. El umbral del 85% reserva margen para contenedores de tamaño variable
// que podrían no caber aunque la ocupación por peso esté por debajo del 100%.
+!pick_least_occupied_shelf(CId, Cat, Urg) <-
    .findall(pair(Occ, S), (shelf_category(S, Cat) & shelf_urgency(S, Urg) &
        shelf_available(S) & shelf_occupancy(S, Occ) & Occ < 85 &
        not expansion_failed_shelf(CId, S)), Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +shelf_selected(CId, ShelfId).

/* ============================================================================
 * ENTREGA EN OUTBOUND
 * Layout de zonas en y=0-1 (de izquierda a derecha):
 *   x=0-2: outbound (rojo) | x=3-4: expansión (amarillo) | x=5-7: entrada (verde)
 * Los robots no deben cruzar estas zonas horizontalmente a y=0-1 porque
 * pueden haber contenedores re-encolados bloqueando el paso.
 * ============================================================================ */

// Yendo a outbound (TX<3, TY<2) desde la zona de estanterías (X>=9):
// 4 pasos que evitan las celdas SHELF en y=2-3 (columnas x=10,12,14,16):
//   Paso 1: ir horizontalmente al corredor x=9 en la fila actual → (9, Y)
//   Paso 2: subir por el corredor libre x=9 hasta y=2             → (9, 2)
//   Paso 3: deslizarse hacia la columna destino a y=2             → (TX, 2)
//   Paso 4: bajar al destino                                      → (TX, TY)
// Ir a (9,Y) primero es un movimiento puramente horizontal que nunca choca con
// estanterías, garantizando la entrada limpia al corredor antes de ascender.
+!navigate(TX, TY) : TX < 3 & TY < 2 & robot_pos(X, Y) & X >= 9 <-
    !navigate(9, Y);
    !navigate(9, 2);
    !navigate(TX, 2);
    !navigate(TX, TY).

// Yendo a outbound (TX<3, TY<2) desde x<9 aproximándose desde arriba (Y>=2):
// subir a y=2, deslizar, bajar. La guarda Y>=2 es crítica: evita que esta regla
// dispare cuando el robot ya está en y=0-1 (p.ej. reintentando drop_in_outbound
// desde dentro del outbound). En ese caso step_with_retry navega directamente
// sin subir a y=2, eliminando el bucle arriba-abajo visible en la entrega.
// La guarda (X\==TX | Y\==2) evita recursión cuando el robot ya está en (TX,2).
+!navigate(TX, TY) : TX < 3 & TY < 2 & robot_pos(X, Y) & X < 9 & Y >= 2 & (X \== TX | Y \== 2) <-
    !navigate(X, 2);
    !navigate(TX, 2);
    !navigate(TX, TY).

// Saliendo de zona izquierda (x<5, y<2) hacia el este, cualquier destino:
// subir a y=2 primero para no cruzar la zona de entrada (x=5-7, y=0-1) que puede
// tener contenedores re-encolados bloqueando el paso, independientemente de TY.
+!navigate(TX, TY) : TX >= 5 & robot_pos(X, Y) & X < 5 & Y < 2 <-
    !navigate(X, 2);
    !navigate(TX, TY).

// En x=17-18 yendo al corredor derecho (TX>=17, TY<2): las celdas y=2-3 de S4
// (x=16-17) bloquean el descenso directo. Rodear por x=19 (columna libre).
+!navigate(TX, TY) : TX >= 17 & TY < 2 & robot_pos(X, Y) & X >= 17 & X < 19 & Y >= 2 <-
    !navigate(19, Y);
    !navigate(TX, TY).

// En x=19, y>=2, yendo al outbound derecho: descender por la columna x=19.
// La guarda TX\==19 evita recursión cuando el !navigate(19,1) interior se reevalúa.
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

-!drop_at_outbound(CId) : outbound_drop_retries(CId, N) & N >= 3 <-
    .abolish(outbound_drop_retries(CId, _));
    !release_zone(outbound);
    .fail.

-!drop_at_outbound(CId) : outbound_drop_retries(CId, N) <-
    N1 = N + 1;
    -outbound_drop_retries(CId, _);
    +outbound_drop_retries(CId, N1);
    !release_zone(outbound);
    .wait(2000);
    !drop_at_outbound(CId).

-!drop_at_outbound(CId) <-
    +outbound_drop_retries(CId, 1);
    !release_zone(outbound);
    .wait(1500);
    !drop_at_outbound(CId).
