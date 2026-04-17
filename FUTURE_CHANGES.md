# 2nd Iteration
The environment can only provide the location of the agents, the shelves and containers.
Temporal control: the scheduler will indicate which packages must be in the outbound area and the time limit by which they must be there (deadline).
Scheduler coordination change: the scheduler will no longer act as the central information provider; robots will query the environment to obtain package locations.
Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow.

# CORRECCIÓN ITERACIÓN 1
Código: 80
- Se debe tener cuidado a la hora de calcular la ruta, puesto que se hace en base a un estado presente del entorno, y no en el tiempo futuro en el que se va a realizar la acción, por lo que ese estado del entorno no se cumpla (puede que al calcular la ruta, no existan obstáculos que si se pueden dar cuando los robots se están moviendo en el entorno). Tiene que ver con: "Distributed coordination among robots to organize themselves autonomously and efficiently, without relying on the scheduler to assign specific tasks, in order to optimize workflow."

# 2nd week

General objective

Adapt the system architecture to introduce the outbound zone and prepare the controlled transition from the inbound cycle to the outbound cycle, incorporating the explicit classification of containers by shelving, while maintaining a lean environment.

Specific objectives

    Adapt the behaviour of the robots so that they:
        query the Scheduler (the Environment provides this information) for container locations,
        maintain local beliefs about the state of the system,
        do not depend on explicit task allocations from other agents (scheduler or supervisor),
        incorporate a second instance of a heavy-duty robot into the system.
    Modify the scheduler so that it:
        does not assign tasks or robots,
        can receive the supervisor’s notification,
        activates the outbound cycle for the corresponding container type,
        stops accepting new containers of that type until storage space becomes available again.