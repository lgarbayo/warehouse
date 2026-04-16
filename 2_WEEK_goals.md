Goals of the week

General objective

Adapt the system architecture to introduce the outbound zone and prepare the controlled transition from the inbound cycle to the outbound cycle, incorporating the explicit classification of containers by shelving, while maintaining a lean environment.

Specific objectives

    Implement the outbound zone in the environment and reorganise the zones:
        the outbound zone is located in the cells: (0,0) (0,1) (1,0) (1,1) (2,0) (2,1).
        the inbound zone is now located in the cells: (5,0) (5,1) (6,0) (6,1) (7,0) (7,1).
        the sorting zone is now located in the cells: (3,0) (3,1) (4,0) (4,1).
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

Mandatory logging

    When the supervisor detects that there is no remaining storage space for a container type, the following event must be displayed in the console:
    EVENT | time=T | agent=supervisor | type=no_space_detected | data=container_type
    where container_type indicates whether the containers are urgent or non-urgent.

    When the scheduler receives the supervisor’s notification and activates the corresponding outbound cycle, the following event must be displayed in the console:
    EVENT | time=T0 | agent=scheduler | type=output_phase_started | data=container_type