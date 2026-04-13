# Future Changes

## Mostrar lista contenedores al final
## Resolver tema de tipos de containers (standard, urgent y fragile)

### Los path_blocked - No route found to (0,0) no cuentan gracias al -!check_queue que los descarta. Por qué? Porque el retorno a base es una funcionalidad de comodidad — si no puede volver, no pasa nada, el robot simplemente se queda donde terminó la última entrega y sigue operativo para la siguiente tarea. Si ese fallo llegara al supervisor contaminaría total_errors y error_rate con algo que no es un error real del sistema. Un robot que no puede volver a su posición inicial no afecta para nada a la operación del almacén.

## 09/04
Errrores generales de laiteracion 1

entorno grueso: el entorno se encarga de objetivos que debe realiar el agente: cálculo de estadísticas, asignar estantería, determinar la posición del siguiente movimiento. El entorno debe proveer solo percepciones primitivas y los agentes ejercen liberación y razonamiento.

There is no formal planning: no action plan is drawn up before execution. The agentes react sequentially. A planning agent RyN, Chapter 11 would generate an optimal plan b ytaking into account all pending containers and the avaliability of robots.

## CORRECCIÓN ITERACIÓN 1
Código: 80
- En el momento en el que están las estanterías llenas, no parece recomendable dejar los contenedores en los pasillos. En tal caso, podrían devolverse a la zona de Entrada o a la de extensión. Esto también puede darse cuando 2 robots seleccionan la misma estantería y el primero, con su contenedor, la llena lo suficiente para que el segundo no pueda depositarla en esa estantería.
- En el supervisor se debe tener cuidado con el envío de mensajes con askOne, puesto que es bloqueante. En el caso de que el robot se encuentre en una tarea larga, bloqueará al supervisor durante mucho tiempo.
- Se debe tener cuidado a la hora de calcular la ruta, puesto que se hace en base a un estado presente del entorno, y no en el tiempo futuro en el que se va a realizar la acción, por lo que ese estado del entorno no se cumpla (puede que al calcular la ruta, no existan obstáculos que si se pueden dar cuando los robots se están moviendo en el entorno).

Memoria: 80
- Se incluyen diagramas y están referenciados en el texto.
- Memoria con carácter LLM. Debe ser pulido este carácter.
- Cómo se tiene en cuenta las etiquetas urgent y fragile en la asignación de los contenedores? Realmente se hace como se dice en la memoria? En código los contenedores son asignados a la cola del correspondiente robot sin tener ninguna matización de si es urgente o fragile.
- El rol que está manteniendo ahora el Scheduler es de broker centralizado, por lo que la arquitectura es centralizada en el Scheduler.
- Ojo con este tipo de afirmaciones: "El supervisor confirma la operación mediante el reporte periódico, que muestra tasas de éxito del 100 % en escenarios sin saturación.". Estas afirmaciones del 100 % sin un respaldo documentado son complicadas de mantener.