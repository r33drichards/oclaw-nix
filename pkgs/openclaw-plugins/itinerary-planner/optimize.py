#!/usr/bin/env python3
"""
OR-Tools VRPTW solver for itinerary optimization.

Reads a JSON problem on stdin, writes the optimal visit order as JSON on stdout.

Input format:
{
  "numLocations": 5,          // 0 = start, 1..N-1 = destinations, last = end (may equal start)
  "travelTimeMatrix": [[...]],// seconds, travelTimeMatrix[i][j] = travel time from i to j
  "timeWindows": [            // one per location
    [earlySeconds, lateSeconds]  // seconds since midnight; use [0, 86400] for fully flexible
  ],
  "durations": [0, 3600, ...],// seconds to spend at each location (0 for start/end)
  "startIndex": 0,
  "endIndex": 4               // can equal startIndex for round-trip
}

Output format:
{
  "order": [0, 2, 1, 3, 4],       // visit order (indices into the locations array)
  "arrivalTimes": [28800, ...],    // arrival time at each stop in order (seconds since midnight)
  "departureTimes": [28800, ...],  // departure time from each stop in order
  "totalTravelTime": 4200,         // total seconds in transit
  "totalWaitTime": 600,            // total seconds waiting for time windows
  "status": "OPTIMAL"              // or "FEASIBLE", "NO_SOLUTION"
}
"""

import json
import sys

from ortools.constraint_solver import routing_enums_pb2, pywrapcp


def solve(problem: dict) -> dict:
    num_locations = problem["numLocations"]
    travel_time_matrix = problem["travelTimeMatrix"]
    time_windows = problem["timeWindows"]
    durations = problem["durations"]
    start_index = problem["startIndex"]
    end_index = problem["endIndex"]

    # OR-Tools data model
    manager = pywrapcp.RoutingIndexManager(
        num_locations,
        1,            # single vehicle (one person)
        [start_index],
        [end_index],
    )
    routing = pywrapcp.RoutingModel(manager)

    # Transit callback: travel time from i to j + time spent at destination i
    def transit_callback(from_index, to_index):
        from_node = manager.IndexToNode(from_index)
        to_node = manager.IndexToNode(to_index)
        travel = travel_time_matrix[from_node][to_node]
        service = durations[from_node]
        return travel + service

    transit_callback_index = routing.RegisterTransitCallback(transit_callback)
    routing.SetArcCostEvaluatorOfAllVehicles(transit_callback_index)

    # Time dimension — tracks cumulative time for time-window constraints
    max_day_seconds = 24 * 3600  # 24 hours
    routing.AddDimension(
        transit_callback_index,
        max_day_seconds,   # max waiting time (slack)
        max_day_seconds,   # max cumulative time
        False,             # don't force start cumul to zero
        "Time",
    )
    time_dimension = routing.GetDimensionOrDie("Time")

    # Apply time windows to each location
    for location_idx in range(num_locations):
        index = manager.NodeToIndex(location_idx)
        tw_start, tw_end = time_windows[location_idx]
        time_dimension.CumulVar(index).SetRange(tw_start, tw_end)

    # Minimize total time (travel + wait), with a soft penalty on waiting
    # The primary cost is arc cost (travel + service time).
    # Add a coefficient on the slack (waiting) to discourage unnecessary waits.
    for i in range(routing.Size()):
        time_dimension.SlackVar(i).SetMax(max_day_seconds)
    # Minimize span = total elapsed time from start to end (captures both travel and wait)
    time_dimension.SetGlobalSpanCostCoefficient(1)

    # Search parameters
    search_params = pywrapcp.DefaultRoutingSearchParameters()
    search_params.first_solution_strategy = (
        routing_enums_pb2.FirstSolutionStrategy.PATH_CHEAPEST_ARC
    )
    search_params.local_search_metaheuristic = (
        routing_enums_pb2.LocalSearchMetaheuristic.GUIDED_LOCAL_SEARCH
    )
    search_params.time_limit.FromSeconds(5)

    solution = routing.SolveWithParameters(search_params)

    if not solution:
        return {"order": [], "arrivalTimes": [], "departureTimes": [],
                "totalTravelTime": 0, "totalWaitTime": 0, "status": "NO_SOLUTION"}

    # Extract the route
    order = []
    arrival_times = []
    departure_times = []
    total_travel = 0
    total_wait = 0

    index = routing.Start(0)
    while not routing.IsEnd(index):
        node = manager.IndexToNode(index)
        time_var = time_dimension.CumulVar(index)
        arrival = solution.Min(time_var)
        departure = arrival + durations[node]

        order.append(node)
        arrival_times.append(arrival)
        departure_times.append(departure)

        # Calculate wait time (difference between earliest we could arrive and window start)
        tw_start = time_windows[node][0]
        if arrival > departure_times[-1] if len(departure_times) > 1 else 0:
            pass  # handled below

        next_index = solution.Value(routing.NextVar(index))
        if not routing.IsEnd(next_index):
            next_node = manager.IndexToNode(next_index)
            travel = travel_time_matrix[node][next_node]
            total_travel += travel

            # Wait time = arrival at next - (departure from current + travel)
            next_arrival = solution.Min(time_dimension.CumulVar(next_index))
            wait = next_arrival - (departure + travel)
            if wait > 0:
                total_wait += wait

        index = next_index

    # Add the final (end) node
    node = manager.IndexToNode(index)
    time_var = time_dimension.CumulVar(index)
    arrival = solution.Min(time_var)
    order.append(node)
    arrival_times.append(arrival)
    departure_times.append(arrival + durations[node])

    # Travel from second-to-last to last
    if len(order) >= 2:
        prev_node = order[-2]
        total_travel += travel_time_matrix[prev_node][node]

    status_map = {
        0: "ROUTING_NOT_SOLVED",
        1: "OPTIMAL",
        2: "FEASIBLE",
        3: "NO_SOLUTION",
        4: "ROUTING_FAIL",
    }
    status = status_map.get(routing.status(), "UNKNOWN")

    return {
        "order": order,
        "arrivalTimes": arrival_times,
        "departureTimes": departure_times,
        "totalTravelTime": total_travel,
        "totalWaitTime": total_wait,
        "status": status,
    }


def main():
    problem = json.load(sys.stdin)
    result = solve(problem)
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
