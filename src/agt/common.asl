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

// ΔT: tiempo mínimo razonable (en ciclos de razonamiento) para que los robots
// urgentes completen sus transportes dado el layout del almacén.
// Layout de referencia: ENTRANCE en y≈0, shelf urgentes en y=2/6/10, grid 20×15.
// Robot ligero (speed=3) ida+vuelta a shelf_1 ≈ 20 pasos → margen con delta_t=30.
delta_t(30).

/* ============================================================================
 * CLASIFICACIÓN DE TIPOS DE CONTENEDOR
 * ============================================================================ */

// Urgentes: containers de tipo "urgent", asignados a shelf_1, shelf_5 o shelf_8
// (una estantería representante de cada categoría de peso).
urgent_container_type("urgent").
urgent_shelf("shelf_1").
urgent_shelf("shelf_5").
urgent_shelf("shelf_8").

// No urgentes: tipos estándar y frágiles.
non_urgent_container_type("standard").
non_urgent_container_type("fragile").
