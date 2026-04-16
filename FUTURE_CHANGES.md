# Future Changes

## Mostrar lista contenedores al final
## Resolver tema de tipos de containers (standard, urgent y fragile)

### Los path_blocked - No route found to (0,0) no cuentan gracias al -!check_queue que los descarta. Por qué? Porque el retorno a base es una funcionalidad de comodidad — si no puede volver, no pasa nada, el robot simplemente se queda donde terminó la última entrega y sigue operativo para la siguiente tarea. Si ese fallo llegara al supervisor contaminaría total_errors y error_rate con algo que no es un error real del sistema. Un robot que no puede volver a su posición inicial no afecta para nada a la operación del almacén.

## 09/04
Errrores generales de laiteracion 1

There is no formal planning: no action plan is drawn up before execution. The agentes react sequentially. A planning agent RyN, Chapter 11 would generate an optimal plan b ytaking into account all pending containers and the avaliability of robots.
Goal -> Draw up a formal plan for how to handle pending containers and robot availability (see Russel and Norvig, Chapter 11).

## CORRECCIÓN ITERACIÓN 1
Código: 80
- Se debe tener cuidado a la hora de calcular la ruta, puesto que se hace en base a un estado presente del entorno, y no en el tiempo futuro en el que se va a realizar la acción, por lo que ese estado del entorno no se cumpla (puede que al calcular la ruta, no existan obstáculos que si se pueden dar cuando los robots se están moviendo en el entorno). Tiene que ver con: "Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow."

Memoria: 80
- Se incluyen diagramas y están referenciados en el texto.
- Memoria con carácter LLM. Debe ser pulido este carácter.
- Cómo se tiene en cuenta las etiquetas urgent y fragile en la asignación de los contenedores? Realmente se hace como se dice en la memoria? En código los contenedores son asignados a la cola del correspondiente robot sin tener ninguna matización de si es urgente o fragile.
- El rol que está manteniendo ahora el Scheduler es de broker centralizado, por lo que la arquitectura es centralizada en el Scheduler.
- Ojo con este tipo de afirmaciones: "El supervisor confirma la operación mediante el reporte periódico, que muestra tasas de éxito del 100 % en escenarios sin saturación.". Estas afirmaciones del 100 % sin un respaldo documentado son complicadas de mantener.

# 2nd Iteration
The environment can only provide the location of the agents, the shelves and containers.
Temporal control: the scheduler will indicate which packages must be in the outbound area and the time limit by which they must be there (deadline).
Scheduler coordination change: the scheduler will no longer act as the central information provider; robots will query the environment to obtain package locations.
Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow.