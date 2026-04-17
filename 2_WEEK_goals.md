Goals of the week

General objective

Adapt the system architecture to introduce the outbound zone and prepare the controlled transition from the inbound cycle to the outbound cycle, incorporating the explicit classification of containers by shelving, while maintaining a lean environment.

Specific objectives

    Adapt the behaviour of the robots so that they:
        query the Scheduler (the Environment provides this information) for container locations,
        maintain local beliefs about the state of the system,
        do not depend on explicit task allocations from other agents (scheduler or supervisor),
        incorporate a second instance of a heavy-duty robot into the system.
    Establish shelving for storing container types:
        shelves S1, S5, S8 store urgent containers.
        shelves S2, S3, S4, S6, S7, S9 store standard and fragile containers.
    Adapt the supervisor to detect lack of storage space:
        detect when there is no available or compatible shelving to store new containers of that type,
        send an explicit message to the scheduler agent indicating that no storage space remains.
    Modify the scheduler so that it:
        does not assign tasks or robots,
        can receive the supervisor’s notification,
        activates the outbound cycle for the corresponding container type,
        stops accepting new containers of that type until storage space becomes available again.