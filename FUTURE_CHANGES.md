# 2nd Iteration

The environment can only provide the location of the agents, the shelves and containers.
Temporal control: the scheduler will indicate which packages must be in the outbound area and the time limit by which they must be there (deadline).
Scheduler coordination change: the scheduler will no longer act as the central information provider; robots will query the environment to obtain package locations.
Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow.

---

El entorno sólo podrá dar la ubicación de los agentes, de las estanterías y los contenedores.
Nueva zona de salida.
Control temporal el scheduler señalará los contenedores que deben estar en la zona de salida y el tiempo límite en el que se deben encontrar allí (deadline).
Coordinación del scheduler deja de ser el proveedor central de información, los robots consultan al entorno la ubicación de contenedores.
Coordinación distribuida entre los robots para organizarse de forma autónoma y eficiente sin depender del scheduler para asignar tareas específicas. Optimizar el flujo de trabajo.

---

> [!NOTE]
> Nota: cambiar light por L, medium por M, heavy por H, heavy por H2??
> Nota: cambiar zonas hardcodeadas?

# 2nd week

General objective

Adapt the system architecture to introduce the outbound zone and prepare the controlled transition from the inbound cycle to the outbound cycle, incorporating the explicit classification of containers by shelving, while maintaining a lean environment.

Specific objectives
    Modify the scheduler so that it:
        does not assign tasks or robots,
        can receive the supervisor’s notification,
        activates the outbound cycle for the corresponding container type,
        stops accepting new containers of that type until storage space becomes available again.

    Modificar el scheduler para que:
        no asigne tareas ni robots,
        pueda recibir el aviso del supervisor,
        active el ciclo de salida del tipo de contenedor correspondiente,
        deje de aceptar nuevos contenedores de ese tipo hasta que quede espacio para nuevos contenedores.