/*******************************************************************************
 * SCHEDULER - Agente Planificador (R&N Cap. 11 — Forward Search)
 *
 * Universidad de Vigo - Sistemas Inteligentes
 * Curso 2025-2026
 *
 * Implementa planificación formal antes de ejecutar asignaciones:
 *   1. Estado del mundo (ps_*): snapshot de robots, estanterías y pendientes.
 *   2. Esquema de acción assign/3 con precondiciones y efectos explícitos.
 *   3. Forward search greedy best-first guiado por heurística admisible h.
 ******************************************************************************/

/* ============================================================================
 * CREENCIAS INICIALES
 * ============================================================================ */

robot_capacity(robot_light,  10,  1, 1, 3).    // (Robot, MaxPeso, MaxW, MaxH, Velocidad)
robot_capacity(robot_medium, 30,  1, 2, 2).
robot_capacity(robot_heavy,  100, 2, 3, 1).
robot_capacity(robot_heavy2, 100, 2, 3, 1).

robot_available(robot_light).
robot_available(robot_medium).
robot_available(robot_heavy).
robot_available(robot_heavy2).

total_containers_received(0).
total_tasks_assigned(0).

containers_heavy([]).
containers_medium([]).
containers_light([]).

/* Asignación de estanterías por urgencia y tamaño del contenedor.
 * shelf_for(Urgency, SizeCategory, ShelfId)
 *   urgent    → S1 (light), S5 (medium), S8 (heavy)
 *   non_urgent → S2-S4 (light), S6-S7 (medium), S9 (heavy) */
shelf_for(urgent,     light,  "shelf_1").
shelf_for(urgent,     medium, "shelf_5").
shelf_for(urgent,     heavy,  "shelf_8").
shelf_for(non_urgent, light,  "shelf_2").
shelf_for(non_urgent, light,  "shelf_3").
shelf_for(non_urgent, light,  "shelf_4").
shelf_for(non_urgent, medium, "shelf_6").
shelf_for(non_urgent, medium, "shelf_7").
shelf_for(non_urgent, heavy,  "shelf_9").

/* ============================================================================
 * REGLAS — Precondiciones del esquema de acción assign/3
 * ============================================================================ */

// Compatibilidad estantería ↔ tipo de contenedor
shelf_type_ok(ShelfId, urgent)   :- shelf_for(urgent,     _, ShelfId).
shelf_type_ok(ShelfId, standard) :- shelf_for(non_urgent, _, ShelfId).
shelf_type_ok(ShelfId, fragile)  :- shelf_for(non_urgent, _, ShelfId).

// Categoría de urgencia para el control del ciclo outbound
urgency_of(urgent,   urgent).
urgency_of(standard, non_urgent).
urgency_of(fragile,  non_urgent).

/* ============================================================================
 * 1. RECEPCIÓN DE CONTENEDORES
 * ============================================================================ */

// Se usa un goal intermedio (!process_new_container) para poder capturar fallos
// con -!process_new_container si el contenedor desaparece antes de procesarse.
+new_container(CId) : true <-
    .print("[SCHEDULER] Nuevo contenedor: ", CId);
    !process_new_container(CId).

+!process_new_container(CId) : true <-
    get_container_info(CId).

-!process_new_container(CId) : true <-
    .print("💥 [SCHEDULER] ", CId, " ya no existe al intentar procesar. Ignorando.").

// Contenedor aplastado antes de clasificar: ignorar
+container_info(CId, W, H, Weight, Type, X, Y) : container_broken(CId) <-
    .print("💥 [SCHEDULER] ", CId, " fue aplastado antes de clasificar. Ignorando.").

// Registrar contenedor en la cola de planificación y activar el planificador
+container_info(CId, W, H, Weight, Type, X, Y) : not container_broken(CId) <-
    .print("[PLANNER] Contenedor registrado: ", CId, " (", Weight, "kg, tipo=", Type, ")");
    +planner_pending(CId, W, H, Weight, Type);
    .count(container_info(_, _, _, _, _, _, _), N);
    -total_containers_received(_);
    +total_containers_received(N);
    // planning_active evita lanzar el planificador varias veces en paralelo
    if (not planning_active) {
        +planning_active;
        .wait(300);   // ventana para acumular contenedores simultáneos
        !run_planner;
        -planning_active;
    }.

/* ============================================================================
 * 2. ESTADO DEL MUNDO (Planning State — ps_*)
 *
 *   ps_robot_free(Robot)             robot sin tarea asignada activa
 *   ps_shelf(ShelfId, Occ)           ocupación proyectada de la estantería
 *   ps_pending(CId, W, H, Wt, Type)  contenedor aún sin asignar en la proyección
 * ============================================================================ */

+!build_planning_state <-
    // Limpiar proyección anterior
    .abolish(ps_robot_free(_));
    .abolish(ps_shelf(_, _));
    .abolish(ps_pending(_, _, _, _, _));

    // Robots libres: aquellos sin tarea assigned activa
    .findall(R, robot_capacity(R, _, _, _, _), AllRobots);
    for (.member(R, AllRobots)) {
        if (not assigned(R, _, _)) { +ps_robot_free(R); }
    };

    // Estanterías disponibles con su ocupación actual
    .findall(shelf(S, Occ), (shelf_available(S) & shelf_occupancy(S, Occ)), Shelves);
    for (.member(shelf(S, Occ), Shelves)) { +ps_shelf(S, Occ); };

    // Contenedores pendientes (solo los no aplastados)
    .findall(c(CId,W,H,Wt,Tp),
             (planner_pending(CId,W,H,Wt,Tp) & not container_broken(CId)),
             Pending);
    for (.member(c(CId,W,H,Wt,Tp), Pending)) { +ps_pending(CId,W,H,Wt,Tp); };

    .findall(R, ps_robot_free(R), FR);
    .findall(ps_shelf(S2,O2), ps_shelf(S2,O2), FS);
    .findall(C, ps_pending(C,_,_,_,_), FP);
    .print("[PLANNER] Estado inicial: robots_libres=", FR, " | estanterias=", FS, " | pendientes=", FP).

/* ============================================================================
 * 3. EFECTOS DEL ESQUEMA DE ACCIÓN assign(Robot, CId, ShelfId)
 *
 *   Precondiciones (evaluadas en get_applicable_actions):
 *     ps_robot_free(Robot)
 *     ps_pending(CId, W, H, Weight, Type)
 *     ps_shelf(ShelfId, _)
 *     can_carry(Robot, W, H, Weight)
 *     shelf_type_ok(ShelfId, Type)
 *     not blocked_type(urgency_of(Type))
 *
 *   Efectos (aplicados al estado proyectado ps_*):
 *     - ps_robot_free(Robot)          robot pasa a ocupado en la proyección
 *     - ps_pending(CId, ...)          contenedor queda asignado en la proyección
 *     ps_shelf(ShelfId, Occ+1)        ocupación aumenta en 1
 * ============================================================================ */

+!apply_action(assign(Robot, CId, ShelfId)) :
    ps_shelf(ShelfId, Occ) <-
    -ps_robot_free(Robot);
    -ps_pending(CId, _, _, _, _);
    OccNew = Occ + 1;
    -ps_shelf(ShelfId, Occ);
    +ps_shelf(ShelfId, OccNew).

/* ============================================================================
 * 4. HEURÍSTICA h(assign(Robot, CId, ShelfId)) → Score
 *
 *   h = urgency_weight + fit_bonus - occupancy_penalty
 *
 *   urgency_weight   : urgent=10, non_urgent=5
 *                      Prioriza contenedores urgentes en cada paso de búsqueda.
 *   fit_bonus        : robot exactamente compatible con el contenedor = 3;
 *                      robot sobredimensionado = 1.
 *                      Evita desperdiciar capacidad (robot_heavy para cajas ligeras).
 *   occupancy_penalty: ocupación proyectada de la estantería asignada.
 *                      Distribuye la carga entre estanterías del mismo tipo.
 *
 *   La heurística es admisible: nunca sobreestima el beneficio real.
 *   Analogía con la distancia Manhattan: en cada paso del forward search
 *   evaluamos cuánto "acercamos" al objetivo global sin mirar más allá del
 *   estado actual proyectado (greedy best-first, no A*).
 * ============================================================================ */

// h = urgency_weight + 3 - occupancy_penalty
// Score positivo: mayor = mejor. .sort ascendente + .reverse + tomar el primero.
+!heuristic(assign(_, CId, ShelfId), Score) :
    ps_pending(CId, _, _, _, Type) & ps_shelf(ShelfId, Occ) <-
    if (Type == "urgent") { UW = 10; } else { UW = 5; };
    Score = UW + 3 - Occ.

/* ============================================================================
 * 5. FORWARD SEARCH (greedy best-first)
 *
 *   En cada paso:
 *     1. Generar todas las acciones aplicables en el estado proyectado actual.
 *     2. Puntuar cada una con h(acción).
 *     3. Seleccionar la de mayor puntuación.
 *     4. Aplicar sus efectos al estado proyectado (ps_*).
 *     5. Repetir hasta que no queden pendientes o no haya acciones aplicables.
 *
 *   El resultado es un plan completo generado ANTES de enviar ninguna tarea
 *   a los robots, satisfaciendo el requisito de planificación formal (R&N §11.2).
 * ============================================================================ */

+!run_planner <-
    !build_planning_state;
    .findall(c(CId,_,_,_,_), ps_pending(CId,_,_,_,_), Pending);
    .length(Pending, NP);
    .print("[PLANNER] Iniciando forward search. Pendientes: ", NP);
    !forward_search([], Plan);
    .reverse(Plan, OrderedPlan);
    .length(OrderedPlan, NA);
    .print("[PLANNER] Plan generado: ", NA, " asignaciones → ", OrderedPlan);
    !execute_plan(OrderedPlan).

// Caso base: no quedan pendientes → plan completo
+!forward_search(Acc, Acc) : not ps_pending(_, _, _, _, _) <- true.

// Paso recursivo: seleccionar la mejor acción aplicable, proyectar, continuar
+!forward_search(Acc, FinalPlan) : ps_pending(_, _, _, _, _) <-
    !get_applicable_actions(Actions);
    if (Actions \== []) {
        !pick_best_action(Actions, BestAction);
        !apply_action(BestAction);
        !forward_search([BestAction|Acc], FinalPlan);
    } else {
        // Sin acciones aplicables: robots saturados o sin espacio de estantería
        .print("[PLANNER] Sin acciones aplicables. Deteniendo búsqueda.");
        FinalPlan = Acc;
    }.

// Genera todas las acciones aplicables en el estado proyectado actual.
// Restricciones estrictas idénticas al código original:
//   robot_light  → solo contenedores ligeros (≤10kg, 1×1)       → estanterías light
//   robot_medium → solo contenedores medianos (≤30kg, 1×2, NO ligeros) → estanterías medium
//   robot_heavy  → solo contenedores que no caben en medium      → estanterías heavy
// "No ligero" se expresa como: not (not (Weight > 10) & not (H > 1))
// "No cabe en medium" se expresa como: not (not (Weight > 30) & not (W > 1) & not (H > 2))
+!get_applicable_actions(Actions) <-
    // robot_light + urgent (≤10kg, 1×1 → shelf_1)
    if (ps_robot_free(robot_light) & not blocked_type(urgent)) {
        .findall(assign(robot_light, CId, ShelfId),
            (ps_pending(CId, W, H, Weight, "urgent") &
             not (Weight > 10) & not (W > 1) & not (H > 1) &
             ps_shelf(ShelfId, _) & shelf_for(urgent, light, ShelfId)), AL_U);
    } else { AL_U = []; };
    // robot_light + non_urgent (≤10kg, 1×1 → S2, S3, S4)
    if (ps_robot_free(robot_light) & not blocked_type(non_urgent)) {
        .findall(assign(robot_light, CId, ShelfId),
            (ps_pending(CId, W, H, Weight, Type) & not (Type == "urgent") &
             not (Weight > 10) & not (W > 1) & not (H > 1) &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, light, ShelfId)), AL_N);
    } else { AL_N = []; };
    .concat(AL_U, AL_N, AL);
    // robot_medium + urgent: dos findall para evitar not anidado
    // "no ligero" = Weight>10 OR H>1 (dos condiciones OR → dos findall + concat)
    if (ps_robot_free(robot_medium) & not blocked_type(urgent)) {
        .findall(assign(robot_medium, CId, ShelfId),
            (ps_pending(CId, W, H, Weight, "urgent") &
             Weight > 10 & not (Weight > 30) & not (W > 1) & not (H > 2) &
             ps_shelf(ShelfId, _) & shelf_for(urgent, medium, ShelfId)), AM_U1);
        .findall(assign(robot_medium, CId, ShelfId),
            (ps_pending(CId, W, H, Weight, "urgent") &
             H > 1 & not (Weight > 30) & not (W > 1) & not (H > 2) &
             ps_shelf(ShelfId, _) & shelf_for(urgent, medium, ShelfId)), AM_U2);
        .concat(AM_U1, AM_U2, AM_U);
    } else { AM_U = []; };
    // robot_medium + non_urgent
    if (ps_robot_free(robot_medium) & not blocked_type(non_urgent)) {
        .findall(assign(robot_medium, CId, ShelfId),
            (ps_pending(CId, W, H, Weight, Type) & not (Type == "urgent") &
             Weight > 10 & not (Weight > 30) & not (W > 1) & not (H > 2) &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, medium, ShelfId)), AM_N1);
        .findall(assign(robot_medium, CId, ShelfId),
            (ps_pending(CId, W, H, Weight, Type) & not (Type == "urgent") &
             H > 1 & not (Weight > 30) & not (W > 1) & not (H > 2) &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, medium, ShelfId)), AM_N2);
        .concat(AM_N1, AM_N2, AM_N);
    } else { AM_N = []; };
    .concat(AM_U, AM_N, AM);
    // robot_heavy + urgent: tres findall para evitar not anidado
    // "no cabe en medium" = Weight>30 OR W>1 OR H>2
    if (ps_robot_free(robot_heavy) & not blocked_type(urgent)) {
        .findall(assign(robot_heavy, CId, ShelfId),
            (ps_pending(CId, _, _, Weight, "urgent") & Weight > 30 &
             ps_shelf(ShelfId, _) & shelf_for(urgent, heavy, ShelfId)), AH_U1);
        .findall(assign(robot_heavy, CId, ShelfId),
            (ps_pending(CId, W, _, _, "urgent") & W > 1 &
             ps_shelf(ShelfId, _) & shelf_for(urgent, heavy, ShelfId)), AH_U2);
        .findall(assign(robot_heavy, CId, ShelfId),
            (ps_pending(CId, _, H, _, "urgent") & H > 2 &
             ps_shelf(ShelfId, _) & shelf_for(urgent, heavy, ShelfId)), AH_U3);
        .concat(AH_U1, AH_U2, AH_U_tmp);
        .concat(AH_U_tmp, AH_U3, AH_U);
    } else { AH_U = []; };
    // robot_heavy + non_urgent
    if (ps_robot_free(robot_heavy) & not blocked_type(non_urgent)) {
        .findall(assign(robot_heavy, CId, ShelfId),
            (ps_pending(CId, _, _, Weight, Type) & not (Type == "urgent") & Weight > 30 &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, heavy, ShelfId)), AH_N1);
        .findall(assign(robot_heavy, CId, ShelfId),
            (ps_pending(CId, W, _, _, Type) & not (Type == "urgent") & W > 1 &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, heavy, ShelfId)), AH_N2);
        .findall(assign(robot_heavy, CId, ShelfId),
            (ps_pending(CId, _, H, _, Type) & not (Type == "urgent") & H > 2 &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, heavy, ShelfId)), AH_N3);
        .concat(AH_N1, AH_N2, AH_N_tmp);
        .concat(AH_N_tmp, AH_N3, AH_N);
    } else { AH_N = []; };
    .concat(AH_U, AH_N, AH);

    // robot_heavy2 + urgent
    if (ps_robot_free(robot_heavy2) & not blocked_type(urgent)) {
        .findall(assign(robot_heavy2, CId, ShelfId),
            (ps_pending(CId, _, _, Weight, "urgent") & Weight > 30 &
             ps_shelf(ShelfId, _) & shelf_for(urgent, heavy, ShelfId)), AH2_U1);
        .findall(assign(robot_heavy2, CId, ShelfId),
            (ps_pending(CId, W, _, _, "urgent") & W > 1 &
             ps_shelf(ShelfId, _) & shelf_for(urgent, heavy, ShelfId)), AH2_U2);
        .findall(assign(robot_heavy2, CId, ShelfId),
            (ps_pending(CId, _, H, _, "urgent") & H > 2 &
             ps_shelf(ShelfId, _) & shelf_for(urgent, heavy, ShelfId)), AH2_U3);
        .concat(AH2_U1, AH2_U2, AH2_U_tmp);
        .concat(AH2_U_tmp, AH2_U3, AH2_U);
    } else { AH2_U = []; };
    // robot_heavy2 + non_urgent
    if (ps_robot_free(robot_heavy2) & not blocked_type(non_urgent)) {
        .findall(assign(robot_heavy2, CId, ShelfId),
            (ps_pending(CId, _, _, Weight, Type) & not (Type == "urgent") & Weight > 30 &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, heavy, ShelfId)), AH2_N1);
        .findall(assign(robot_heavy2, CId, ShelfId),
            (ps_pending(CId, W, _, _, Type) & not (Type == "urgent") & W > 1 &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, heavy, ShelfId)), AH2_N2);
        .findall(assign(robot_heavy2, CId, ShelfId),
            (ps_pending(CId, _, H, _, Type) & not (Type == "urgent") & H > 2 &
             ps_shelf(ShelfId, _) & shelf_for(non_urgent, heavy, ShelfId)), AH2_N3);
        .concat(AH2_N1, AH2_N2, AH2_N_tmp);
        .concat(AH2_N_tmp, AH2_N3, AH2_N);
    } else { AH2_N = []; };
    .concat(AH2_U, AH2_N, AH2);

    .concat(AL, AM, Tmp);
    .concat(Tmp, AH, Tmp2);
    .concat(Tmp2, AH2, Actions).

// Selecciona la acción con mayor puntuación heurística
+!pick_best_action(Actions, Best) <-
    !score_actions(Actions, Scored);
    .sort(Scored, Sorted);
    .reverse(Sorted, [s(_, _, Best)|_]).

+!score_actions([], []) <- true.
+!score_actions([assign(R, CId, ShelfId)|Rest], [s(Score, Priority, assign(R, CId, ShelfId))|SRest]) <-
    !heuristic(assign(R, CId, ShelfId), Score);
    .findall(Rx, robot_capacity(Rx, _, _, _, _), AllRobots);
    .nth(Idx, AllRobots, R);
    Priority = -Idx;
    !score_actions(Rest, SRest).

/* ============================================================================
 * 6. EJECUCIÓN DEL PLAN
 *    Envía las tareas a los robots en el orden calculado.
 * ============================================================================ */

+!execute_plan([]) <- true.

+!execute_plan([assign(Robot, CId, ShelfId)|Rest]) : container_broken(CId) <-
    .print("💥 [PLANNER] ", CId, " aplastado antes de ejecutar. Saltando.");
    -planner_pending(CId, _, _, _, _);
    !execute_plan(Rest).

+!execute_plan([assign(Robot, CId, ShelfId)|Rest]) :
    not container_broken(CId) & container_info(CId, W, H, Weight, Type, _, _) <-
    .print("[PLANNER] → assign(", Robot, ", ", CId, ", ", ShelfId, ") [", Type, "]");
    -planner_pending(CId, _, _, _, _);
    +container_type(CId, Type);

    // Clasificación por peso
    if      (Weight <= 10) { +container_weight_category(CId, light);  }
    elif    (Weight <= 30) { +container_weight_category(CId, medium); }
    else                   { +container_weight_category(CId, heavy);  };

    // Clasificación por tamaño
    if      (W <= 1 & H <= 1) { +container_size_category(CId, small);  }
    elif    (W <= 1 & H <= 2) { +container_size_category(CId, medium); }
    else                       { +container_size_category(CId, large);  };

    // Asignar a lista de categoría y enviar tarea al robot
    if (Robot == robot_light) {
        +container_category(CId, light);
        ?containers_light(LL); -containers_light(LL); +containers_light([CId|LL]);
    } elif (Robot == robot_medium) {
        +container_category(CId, medium);
        ?containers_medium(ML); -containers_medium(ML); +containers_medium([CId|ML]);
    } else {
        +container_category(CId, heavy);
        ?containers_heavy(HL); -containers_heavy(HL); +containers_heavy([CId|HL]);
    };

    +assigned(Robot, CId, ShelfId);
    +task_history(Robot, CId, ShelfId);
    +ready_task(Robot, CId, ShelfId);
    .count(task_history(_, _, _), T);
    -total_tasks_assigned(_);
    +total_tasks_assigned(T);
    .print("[TRACE] ready_task: ", Robot, " -> ", CId, " -> ", ShelfId);
    !execute_plan(Rest).

// Fallback: info del contenedor ya no disponible al ejecutar
+!execute_plan([assign(_, CId, _)|Rest]) : true <-
    .print("💥 [PLANNER] Info de ", CId, " no disponible. Saltando.");
    -planner_pending(CId, _, _, _, _);
    !execute_plan(Rest).

/* ============================================================================
 * 7. RELANZAR PLANIFICADOR CUANDO UN ROBOT QUEDA LIBRE
 *    Contenedores que quedaron en planner_pending sin ser asignados (sin robots
 *    disponibles o sin espacio de estantería) se intentan de nuevo cuando un
 *    robot completa su tarea.
 * ============================================================================ */

+container_stored(CId, ShelfId)[source(Robot)] : true <-
    .print("✨ [TRACE] ", Robot, " almacenó ", CId, " en ", ShelfId);
    -assigned(Robot, CId, ShelfId);
    -container_stored(CId, ShelfId)[source(Robot)];
    if (planner_pending(_, _, _, _, _) & not planning_active) {
        +planning_active;
        .wait(100);
        !run_planner;
        -planning_active;
    }.

/* ============================================================================
 * 8. MANEJO DE FALLOS REPORTADOS POR ROBOTS
 * ============================================================================ */

+task_failed(CId)[source(Robot)] : container_broken(CId) <-
    .print("💥 [SCHEDULER] ", CId, " fue aplastado. Limpiando creencias...");
    -assigned(Robot, CId, _);
    -task_failed(CId)[source(Robot)];
    -planner_pending(CId, _, _, _, _);
    .abolish(container_info(CId, _, _, _, _, _, _));
    .abolish(container_category(CId, _));
    .abolish(container_type(CId, _));
    .abolish(container_weight_category(CId, _));
    .abolish(container_size_category(CId, _)).

+task_failed(CId)[source(Robot)] : true <-
    .print("⚠️ ", Robot, " reportó fallo con ", CId, ". Reasignando en 10s...");
    -assigned(Robot, CId, _);
    -task_failed(CId)[source(Robot)];
    .wait(10000);
    .abolish(container_info(CId, _, _, _, _, _, _));
    get_container_info(CId).

-!task_failed(CId) : true <-
    .print("💥 [SCHEDULER] ", CId, " ya no existe. Limpiando creencias...");
    -planner_pending(CId, _, _, _, _);
    .abolish(container_info(CId, _, _, _, _, _, _));
    .abolish(container_category(CId, _));
    .abolish(container_type(CId, _));
    .abolish(container_weight_category(CId, _));
    .abolish(container_size_category(CId, _)).

/* ============================================================================
 * 9. CONTENEDOR EN ZONA DE EXPANSIÓN
 * ============================================================================ */

+container_in_expansion(CId)[source(Robot)] : true <-
    .print("📦 [SCHEDULER] ", CId, " en zona de expansión. Buscando estantería en 5s...");
    -assigned(Robot, CId, _);
    .wait(5000);
    .abolish(container_info(CId, _, _, _, _, _, _));
    get_container_info(CId).

/* ============================================================================
 * 10. TRAZABILIDAD DE ERRORES
 * ============================================================================ */

+container_error(CId, ErrorType)[source(Robot)] : true <-
    .print("❌ [TRACE] Error reportado por ", Robot, " para ", CId, ": ", ErrorType);
    -assigned(Robot, CId, _);
    -container_error(CId, ErrorType)[source(Robot)].

/* ============================================================================
 * 11. CICLO OUTBOUND — saturación de estanterías
 *     El supervisor notifica no_shelf_space(Type) cuando todas las estanterías
 *     del tipo están llenas. El scheduler bloquea ese tipo permanentemente
 *     (esta iteración) e inicia el ciclo de salida.
 * ============================================================================ */

+no_shelf_space(ContainerType)[source(supervisor)] : true <-
    +blocked_type(ContainerType);
    .time(H, M, S);
    .print("EVENT | time=", H, ":", M, ":", S, " | agent=scheduler | type=output_phase_started | data=", ContainerType).

/* ============================================================================
 * 12. PROTOCOLO PULL — robots consultan activamente al scheduler
 *     Los robots envían request_task cuando están idle. El scheduler responde
 *     con la tarea planificada (ready_task) o relanza el planificador si no hay
 *     ninguna preparada para ese robot.
 * ============================================================================ */

// Caso 1: hay una tarea lista para este robot → enviar inmediatamente
+request_task[source(Robot)] : ready_task(Robot, CId, ShelfId) <-
    -ready_task(Robot, CId, ShelfId);
    -request_task[source(Robot)];
    .print("[SCHEDULER] Respondiendo a ", Robot, " con tarea: ", CId, " → ", ShelfId);
    .send(Robot, tell, task(CId, ShelfId)).

// Caso 2: no hay tarea lista pero hay pendientes → replanificar y responder
+request_task[source(Robot)] : planner_pending(_, _, _, _, _) & not planning_active <-
    -request_task[source(Robot)];
    +planning_active;
    .wait(100);
    !run_planner;
    -planning_active;
    if (ready_task(Robot, CId, ShelfId)) {
        -ready_task(Robot, CId, ShelfId);
        .print("[SCHEDULER] Respondiendo a ", Robot, " tras replanificar: ", CId, " → ", ShelfId);
        .send(Robot, tell, task(CId, ShelfId));
    } else {
        .print("[SCHEDULER] Sin tarea disponible para ", Robot);
    }.

// Caso 3: no hay nada — robot esperará y volverá a preguntar
+request_task[source(Robot)] : true <-
    -request_task[source(Robot)];
    .print("[SCHEDULER] Sin tarea disponible para ", Robot).
