# Changes

## Corrección de entorno grueso: asignación de estanterías movida al agente scheduler

### Problema
El entorno tenía `findBestShelf()` y `executeGetFreeShelf()` en `WarehouseArtifact.java`. El scheduler simplemente llamaba `get_free_shelf(CId)` y el entorno decidía qué estantería asignar — filtrando por categoría, ordenando por ocupación y devolviendo la mejor. Esto es entorno grueso: el entorno realizaba razonamiento que corresponde al agente.

### Solución

#### Entorno: solo expone percepciones primitivas

Se eliminaron `findBestShelf`, `executeGetFreeShelf` y el case `"get_free_shelf"`. En su lugar el entorno emite dos tipos de percepción al scheduler:

- **`shelf_available("shelf_1")`** — se emite al inicializar cada estantería y se retira con `removePerceptsByUnif` cuando `shelf.isFull()` tras un `drop_at`. Indica simplemente que la estantería tiene capacidad.
- **`shelf_occupancy("shelf_1", 42)`** — el porcentaje de ocupación actual redondeado a entero. Se emite al inicializar (0%) y se actualiza tras cada `drop_at` exitoso. Dato puro: el entorno mide, no interpreta.

#### Scheduler: razona sobre qué estantería usar

Se añaden creencias estáticas que representan el conocimiento propio del agente sobre el layout del almacén:

```agentspeak
shelf_category("shelf_1", light).
shelf_category("shelf_2", light).
shelf_category("shelf_3", light).
shelf_category("shelf_4", light).
shelf_category("shelf_5", medium).
shelf_category("shelf_6", medium).
shelf_category("shelf_7", medium).
shelf_category("shelf_8", heavy).
shelf_category("shelf_9", heavy).
```

La lógica de asignación se implementa con cuatro planes `+!assign_shelf` que Jason prueba en orden:

1. **Ligero** (`Weight ≤ 10, W ≤ 1, H ≤ 1`) → estanterías `light`
2. **Mediano** (`Weight ≤ 30, W ≤ 1, H ≤ 2`) → estanterías `medium`
3. **Pesado/grande** → estanterías `heavy`
4. **Fallback anti-starvation** → cualquier estantería disponible (si la categoría preferida está llena)

Los planes 1-3 usan la variable `ExS` en la guardia para verificar que existe al menos una estantería de la categoría con disponibilidad (`shelf_category(ExS, Cat) & shelf_available(ExS)`). Si la guardia falla, Jason prueba automáticamente el siguiente plan — el fallback entre categorías es implícito, igual que en el antiguo `findBestShelf`.

#### Plan auxiliar `+!pick_least_occupied`

Para elegir entre todas las estanterías disponibles de una categoría se replica el criterio de `findBestShelf` (ordenar por ocupación, tomar la de menor carga):

```agentspeak
+!pick_least_occupied(CId, Cat) <-
    .findall(pair(Occ, S),
             (shelf_category(S, Cat) & shelf_available(S) & shelf_occupancy(S, Occ)),
             Pairs);
    .sort(Pairs, [pair(_, ShelfId)|_]);
    +free_shelf(CId, ShelfId).
```

`.findall` recoge todos los pares `(ocupación, id)`. `.sort` los ordena por el primer argumento del término `pair` — Jason compara términos compuestos argumento a argumento, por lo que `pair(0,"shelf_2") < pair(15,"shelf_1")`. El primer elemento de la lista ordenada es siempre la menos ocupada.

Se usa `pair(Occ, S)` como functor explícito en lugar de `Occ-S` porque Jason evalúa el operador `-` como aritmética, lo que produce `ArithExpr: value is not a number` al intentar restar un átomo de un número.

### Resumen de cambios

| Archivo | Eliminado | Añadido |
|---|---|---|
| `WarehouseArtifact.java` | `findBestShelf`, `executeGetFreeShelf`, case `"get_free_shelf"` | `emitShelfAvailable`, `emitShelfOccupancy` |
| `scheduler.asl` | `get_free_shelf(CId)` | `shelf_category` beliefs, 4 planes `assign_shelf`, `pick_least_occupied` |

## Sustitución del algoritmo de pathfinding: BFS → Movimiento coordinado con waypoints

### Problema
El algoritmo BFS (`calcularRuta`) utilizado para la navegación de robots era inadecuado:
- Requería estructuras de datos proporcionales al tamaño del grid: `HashMap<List<Integer>, List<Integer>>` para rastrear padres y `ArrayDeque` para la cola de exploración. En el peor caso exploraba los 300 nodos del grid (20×15) por cada paso.
- Calculaba la ruta completa de una vez aunque solo se necesitara el siguiente paso.
- La reconstrucción de la ruta (`construirRutaFinal`) añadía una pasada adicional hacia atrás sobre el mapa de padres.

### Solución: movimiento coordinado inspirado en el robot doméstico

Se reemplazaron `calcularRuta` y `construirRutaFinal` por tres métodos nuevos:

#### `nextCoordinateStep(fromX, fromY, toX, toY, avoidRobots)`
Calcula el siguiente paso en O(1) sin estructuras auxiliares, siguiendo el mismo principio que el `moveTowards` del robot doméstico de Jason:

```java
int dx = Integer.compare(toX, fromX);  // -1, 0 o +1
int dy = Integer.compare(toY, fromY);  // -1, 0 o +1
boolean xFirst = Math.abs(toX - fromX) >= Math.abs(toY - fromY);
```

Se prioriza el eje con mayor distancia Manhattan restante. Si ese eje está bloqueado, se intenta el perpendicular. Si ambos están bloqueados, devuelve lista vacía y el robot cede el paso.

A diferencia del robot doméstico (entorno sin obstáculos), este método delega la comprobación de obstáculos en `isFreeStep`.

#### Comportamiento visual: escalera diagonal ("zigzag")
Al alternar entre los dos ejes según cuál tiene mayor distancia restante, el robot traza el camino diagonal más corto posible en un grid ortogonal. Visualmente produce un patrón de escalera — una secuencia de pasos horizontales y verticales alternados que converge en diagonal hacia el destino. Esto no es un error sino el equivalente Manhattan de una línea recta diagonal, y es exactamente el comportamiento del robot doméstico.

#### `isFreeStep(x, y, avoidRobots)`
Comprueba que una celda es transitable:
1. Dentro del mapa
2. No es `SHELF` ni `BLOCKED`
3. No tiene un contenedor no recogido (`hayContenedorEn`)
4. Si `avoidRobots=true`, no está ocupada por otro robot

La comprobación de contenedores es crítica: sin ella el greedy navega en línea recta a través de la celda del contenedor destino aplastándolo antes de recogerlo. El BFS original incluía `!hayContenedorEn` al expandir nodos por la misma razón. Al restaurar esta comprobación, si la ruta directa pasa por la celda del contenedor `doMoveTo` falla, y `executeMoveToContainer` prueba automáticamente la siguiente celda adyacente libre.

#### `computeWaypointPath(fromX, fromY, toX, toY)`
En la zona de almacenamiento (x≥10) las estanterías forman filas compactas que el greedy no puede atravesar. Se usa `x=9` como corredor vertical siempre libre (no hay estanterías en x<10) y los corredores horizontales del layout como puntos de paso seguros:

```
y=1   — sobre estanterías pequeñas  (x=10..17, y=2-3)
y=4-5 — entre pequeñas y medianas
y=8-9 — entre medianas y grandes
y=13  — bajo estanterías grandes    (x=10..17, y=10-12)
```

Para cualquier destino en la zona de almacenamiento el path es:
```
posición_actual → (9, targetY) → (targetX, targetY)
```

El primer waypoint `(9, targetY)` garantiza que el robot entra al pasillo correcto antes de deslizarse horizontalmente. Si el robot ya está en el mismo corredor que el destino (`fromY == targetY` y es fila de corredor libre), va directo sin waypoint intermedio.

### Acceso a estanterías desde el corredor inferior

`executeMoveToShelf` itera las celdas adyacentes a la estantería en el orden: fila superior → fila inferior → laterales. En condiciones normales el robot accede desde el corredor superior (p.ej. y=5 para estanterías medianas). Si ese corredor está bloqueado por contenedores soltados (p.ej. por `shelf_full`), `doMoveTo` falla para esas celdas y `executeMoveToShelf` prueba automáticamente las del corredor inferior (p.ej. y=8). El depósito funciona igual desde cualquier lado: `drop_at` solo comprueba distancia, no dirección de acceso.

### Resumen de cambios en `WarehouseArtifact.java`

| Eliminado | Añadido |
|---|---|
| `calcularRuta` (BFS, O(W×H)) | `nextCoordinateStep` (greedy coordinado, O(1)) |
| `construirRutaFinal` | `isFreeStep` |
| — | `computeWaypointPath` |
| — | `isCorridorRow` |

El método `doMoveTo` se refactorizó para navegar waypoint a waypoint usando `nextCoordinateStep` en cada iteración, manteniendo la misma lógica de yield (espera 1s si bloqueado por robot, activa `avoidRobots=true` tras 3s).
