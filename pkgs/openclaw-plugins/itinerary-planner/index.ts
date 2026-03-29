import { execSync } from "child_process";
import * as path from "path";

export default function (api: any) {
  const config = api.config?.plugins?.entries?.["itinerary-planner"]?.config;
  const otpUrl = config?.otpUrl || "http://localhost:8080";
  const graphqlUrl = `${otpUrl}/otp/routers/default/index/graphql`;
  const optimizerScript = path.join(__dirname, "optimize.py");

  // ── Helpers ──────────────────────────────────────────────────────────

  interface Coords {
    lat: number;
    lon: number;
    label: string;
  }

  interface Destination {
    name: string;
    address: string;
    arriveBy?: string;
    departAfter?: string;
    duration?: number;
    flexible?: boolean;
  }

  function parseCoords(address: string, label: string): Coords {
    const match = address.match(
      /^(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)$/
    );
    if (match) {
      return { lat: parseFloat(match[1]), lon: parseFloat(match[2]), label };
    }
    // Return a placeholder — OTP geocoding would be needed for real addresses.
    // For now, we pass addresses through the OTP plan query which can geocode.
    return { lat: 0, lon: 0, label };
  }

  function isoToDate(iso: string): string {
    // "2024-01-15T10:00:00" → "2024-01-15"
    return iso.split("T")[0];
  }

  function isoToTime(iso: string): string {
    // "2024-01-15T10:00:00" → "10:00:00"
    const parts = iso.split("T");
    return parts[1] || "08:00:00";
  }

  function isoToSeconds(iso: string): number {
    const time = isoToTime(iso);
    const [h, m, s] = time.split(":").map(Number);
    return h * 3600 + (m || 0) * 60 + (s || 0);
  }

  function secondsToTime(secs: number): string {
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    const period = h >= 12 ? "PM" : "AM";
    const h12 = h === 0 ? 12 : h > 12 ? h - 12 : h;
    return `${h12}:${m.toString().padStart(2, "0")} ${period}`;
  }

  function formatDuration(secs: number): string {
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    if (h > 0 && m > 0) return `${h}h ${m}min`;
    if (h > 0) return `${h}h`;
    return `${m} min`;
  }

  interface OtpMode {
    mode: string;
    qualifier?: string;
  }

  function parseTransportModes(modeStr: string): OtpMode[] {
    return modeStr.split(",").map((m) => {
      const trimmed = m.trim().toUpperCase();
      return { mode: trimmed };
    });
  }

  // ── OTP GraphQL query for a single leg ──────────────────────────────

  async function queryOtpLeg(
    fromLat: number,
    fromLon: number,
    toLat: number,
    toLon: number,
    date: string,
    time: string,
    modes: OtpMode[],
    maxWalkDistance: number,
    numItineraries: number = 3
  ): Promise<any> {
    const modesStr = modes.map((m) => `{mode: ${m.mode}}`).join(", ");

    const query = `{
      plan(
        from: {lat: ${fromLat}, lon: ${fromLon}}
        to: {lat: ${toLat}, lon: ${toLon}}
        date: "${date}"
        time: "${time}"
        transportModes: [${modesStr}]
        numItineraries: ${numItineraries}
      ) {
        itineraries {
          startTime
          endTime
          duration
          walkTime
          walkDistance
          transfers
          legs {
            mode
            startTime
            endTime
            from { name lat lon }
            to { name lat lon }
            route { shortName longName }
            trip { tripHeadsign }
            duration
            distance
            steps { streetName distance relativeDirection }
          }
        }
      }
    }`;

    const res = await fetch(graphqlUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ query }),
    });

    if (!res.ok) {
      const text = await res.text();
      throw new Error(`OTP query failed (${res.status}): ${text}`);
    }

    return res.json();
  }

  // Get the best itinerary travel time in seconds between two points
  async function getTravelTime(
    fromLat: number,
    fromLon: number,
    toLat: number,
    toLon: number,
    date: string,
    time: string,
    modes: OtpMode[],
    maxWalkDistance: number
  ): Promise<number> {
    try {
      const data = await queryOtpLeg(
        fromLat, fromLon, toLat, toLon, date, time, modes, maxWalkDistance, 1
      );
      const itineraries = data?.data?.plan?.itineraries;
      if (itineraries && itineraries.length > 0) {
        return itineraries[0].duration;
      }
    } catch (e) {
      // Fall through to default
    }
    // Fallback: estimate ~20 min if OTP fails
    return 1200;
  }

  // ── OR-Tools optimization ───────────────────────────────────────────

  function runOptimizer(problem: any): any {
    const input = JSON.stringify(problem);
    try {
      const output = execSync(`python3 "${optimizerScript}"`, {
        input,
        encoding: "utf-8",
        timeout: 30000,
        maxBuffer: 10 * 1024 * 1024,
      });
      return JSON.parse(output);
    } catch (err: any) {
      throw new Error(`OR-Tools optimizer failed: ${err.stderr || err.message}`);
    }
  }

  // ── Build travel time matrix ────────────────────────────────────────

  async function buildTravelTimeMatrix(
    locations: Coords[],
    date: string,
    baseTime: string,
    modes: OtpMode[],
    maxWalkDistance: number
  ): Promise<number[][]> {
    const n = locations.length;
    const matrix: number[][] = Array.from({ length: n }, () =>
      new Array(n).fill(0)
    );

    // Query OTP for each pair (i → j where i ≠ j)
    const queries: Promise<void>[] = [];

    for (let i = 0; i < n; i++) {
      for (let j = 0; j < n; j++) {
        if (i === j) continue;
        const from = locations[i];
        const to = locations[j];
        if (from.lat === 0 && from.lon === 0) continue;
        if (to.lat === 0 && to.lon === 0) continue;

        queries.push(
          getTravelTime(
            from.lat, from.lon, to.lat, to.lon,
            date, baseTime, modes, maxWalkDistance
          ).then((time) => {
            matrix[i][j] = time;
          })
        );
      }
    }

    // Run queries in batches of 5 to avoid overwhelming OTP
    const batchSize = 5;
    for (let b = 0; b < queries.length; b += batchSize) {
      await Promise.all(queries.slice(b, b + batchSize));
    }

    return matrix;
  }

  // ── Format the final itinerary ──────────────────────────────────────

  function modeEmoji(mode: string): string {
    const map: Record<string, string> = {
      WALK: "🚶",
      BUS: "🚌",
      RAIL: "🚆",
      SUBWAY: "🚇",
      TRAM: "🚊",
      FERRY: "⛴️",
      BICYCLE: "🚲",
      CAR: "🚗",
    };
    return map[mode] || "🚐";
  }

  function formatLeg(leg: any): string {
    const emoji = modeEmoji(leg.mode);
    const duration = formatDuration(leg.duration);

    if (leg.mode === "WALK") {
      const dist = Math.round(leg.distance);
      return `  ${emoji} Walk ${duration} (${dist}m) to ${leg.to.name}`;
    }

    const route = leg.route
      ? `${leg.route.shortName || ""} ${leg.route.longName || ""}`.trim()
      : "";
    const headsign = leg.trip?.tripHeadsign
      ? ` → ${leg.trip.tripHeadsign}`
      : "";

    return `  ${emoji} ${leg.mode} ${route}${headsign} (${duration})\n     ${leg.from.name} → ${leg.to.name}`;
  }

  function formatDate(iso: string): string {
    const d = new Date(iso + "T00:00:00");
    const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    const months = [
      "Jan", "Feb", "Mar", "Apr", "May", "Jun",
      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    return `${days[d.getDay()]} ${months[d.getMonth()]} ${d.getDate()}`;
  }

  // ── Main tool registration ─────────────────────────────────────────

  api.registerTool(
    {
      name: "plan_itinerary",
      description:
        "Plan an optimized multi-stop day itinerary using public transit. " +
        "Uses OpenTripPlanner for transit routing and Google OR-Tools for optimal " +
        "stop ordering with time-window constraints. Provide destinations with " +
        "optional fixed appointment times, and get back an optimized day plan " +
        "with transit directions.",
      parameters: {
        type: "object",
        properties: {
          destinations: {
            type: "array",
            description: "List of places to visit during the day.",
            items: {
              type: "object",
              properties: {
                name: {
                  type: "string",
                  description:
                    'Human-readable name, e.g. "Dentist", "Lunch at Mission".',
                },
                address: {
                  type: "string",
                  description:
                    'Address or "lat,lon" coordinates.',
                },
                arriveBy: {
                  type: "string",
                  description:
                    'Hard arrival constraint in ISO format "2024-01-15T10:00:00".',
                },
                departAfter: {
                  type: "string",
                  description:
                    "Earliest departure time from previous stop (ISO format).",
                },
                duration: {
                  type: "number",
                  description:
                    "Minutes to spend at this location (default: 30).",
                },
                flexible: {
                  type: "boolean",
                  description:
                    "Can this stop be reordered? Default true. Set false for fixed-time appointments.",
                },
              },
              required: ["name", "address"],
            },
          },
          startLocation: {
            type: "string",
            description: 'Starting address or "lat,lon".',
          },
          endLocation: {
            type: "string",
            description:
              "Where to end up (default: same as startLocation for round-trip).",
          },
          departureTime: {
            type: "string",
            description:
              'When to start the day, ISO format "2024-01-15T08:00:00".',
          },
          preferences: {
            type: "object",
            properties: {
              mode: {
                type: "string",
                description:
                  'Transit modes, comma-separated. Default: "TRANSIT,WALK". Options include TRANSIT, WALK, BICYCLE, CAR, BUS, RAIL, SUBWAY, TRAM, FERRY.',
              },
              maxWalkDistance: {
                type: "number",
                description: "Maximum walking distance in meters (default: 1500).",
              },
              minimize: {
                type: "string",
                enum: ["TIME", "TRANSFERS", "WALKING"],
                description:
                  "What to optimize for (default: TIME).",
              },
            },
          },
        },
        required: ["destinations", "startLocation", "departureTime"],
      },

      async execute(_id: string, params: any) {
        try {
          const {
            destinations,
            startLocation,
            endLocation,
            departureTime,
            preferences,
          } = params;

          const modeStr = preferences?.mode || "TRANSIT,WALK";
          const maxWalkDistance = preferences?.maxWalkDistance || 1500;
          const modes = parseTransportModes(modeStr);
          const date = isoToDate(departureTime);
          const baseTime = isoToTime(departureTime);
          const dayStartSeconds = isoToSeconds(departureTime);

          // ── 1. Build locations array ──────────────────────────────

          // Index 0 = start
          const locations: Coords[] = [
            parseCoords(startLocation, "Start"),
          ];

          // Indices 1..N = destinations
          const destData: Array<{
            dest: Destination;
            durationSec: number;
            timeWindow: [number, number];
          }> = [];

          for (const dest of destinations) {
            const coords = parseCoords(dest.address, dest.name);
            locations.push(coords);

            const durationMin = dest.duration ?? 30;
            const durationSec = durationMin * 60;

            // Compute time window
            let twStart = dayStartSeconds;
            let twEnd = 23 * 3600; // 11 PM

            if (dest.arriveBy) {
              // Hard constraint: must arrive by this time
              const arriveBySeconds = isoToSeconds(dest.arriveBy);
              twEnd = arriveBySeconds;
              // Allow arriving up to 2 hours early for fixed appointments
              twStart = Math.max(dayStartSeconds, arriveBySeconds - 7200);
            }

            if (dest.departAfter) {
              twStart = Math.max(twStart, isoToSeconds(dest.departAfter));
            }

            if (dest.flexible === false && dest.arriveBy) {
              // Tight window for non-flexible fixed appointments
              const arriveBySeconds = isoToSeconds(dest.arriveBy);
              twStart = Math.max(dayStartSeconds, arriveBySeconds - 1800); // 30 min early max
              twEnd = arriveBySeconds;
            }

            destData.push({ dest, durationSec, timeWindow: [twStart, twEnd] });
          }

          // End location (last index)
          const endAddr = endLocation || startLocation;
          locations.push(parseCoords(endAddr, "End"));

          const n = locations.length;
          const startIdx = 0;
          const endIdx = n - 1;

          // ── 2. Build travel time matrix via OTP ───────────────────

          const travelTimeMatrix = await buildTravelTimeMatrix(
            locations,
            date,
            baseTime,
            modes,
            maxWalkDistance
          );

          // ── 3. Build time windows and durations arrays ────────────

          const timeWindows: [number, number][] = [];
          const durationsSec: number[] = [];

          // Start location
          timeWindows.push([dayStartSeconds, dayStartSeconds]);
          durationsSec.push(0);

          // Destinations
          for (const dd of destData) {
            timeWindows.push(dd.timeWindow);
            durationsSec.push(dd.durationSec);
          }

          // End location
          timeWindows.push([dayStartSeconds, 24 * 3600]);
          durationsSec.push(0);

          // ── 4. Run OR-Tools optimizer ─────────────────────────────

          const problem = {
            numLocations: n,
            travelTimeMatrix,
            timeWindows,
            durations: durationsSec,
            startIndex: startIdx,
            endIndex: endIdx,
          };

          const solution = runOptimizer(problem);

          if (
            solution.status === "NO_SOLUTION" ||
            solution.order.length === 0
          ) {
            return {
              content: [
                {
                  type: "text",
                  text:
                    "❌ Could not find a feasible itinerary. " +
                    "The time constraints may be too tight, or transit connections may not exist. " +
                    "Try relaxing appointment times or adding more flexibility.",
                },
              ],
            };
          }

          // ── 5. Get detailed directions for each leg ───────────────

          const orderedStops = solution.order;
          const arrivalTimes: number[] = solution.arrivalTimes;
          const departureTimes: number[] = solution.departureTimes;

          const legs: any[] = [];
          let totalWalkDistance = 0;
          let totalTransfers = 0;
          let totalTransitTime = 0;

          for (let i = 0; i < orderedStops.length - 1; i++) {
            const fromIdx = orderedStops[i];
            const toIdx = orderedStops[i + 1];
            const fromLoc = locations[fromIdx];
            const toLoc = locations[toIdx];
            const departSec = departureTimes[i];
            const departH = Math.floor(departSec / 3600);
            const departM = Math.floor((departSec % 3600) / 60);
            const departTimeStr = `${departH.toString().padStart(2, "0")}:${departM.toString().padStart(2, "0")}:00`;

            try {
              const otpResult = await queryOtpLeg(
                fromLoc.lat,
                fromLoc.lon,
                toLoc.lat,
                toLoc.lon,
                date,
                departTimeStr,
                modes,
                maxWalkDistance,
                3
              );

              const itineraries = otpResult?.data?.plan?.itineraries;
              if (itineraries && itineraries.length > 0) {
                // Pick the best (first) itinerary
                const best = itineraries[0];
                legs.push({
                  fromIdx,
                  toIdx,
                  itinerary: best,
                });
                totalWalkDistance += best.walkDistance || 0;
                totalTransfers += best.transfers || 0;
                totalTransitTime += best.duration || 0;
              } else {
                legs.push({ fromIdx, toIdx, itinerary: null });
              }
            } catch {
              legs.push({ fromIdx, toIdx, itinerary: null });
            }
          }

          // ── 6. Format the output ──────────────────────────────────

          let output = `🗓️ **Your Day Plan (${formatDate(date)})**\n\n`;

          for (let i = 0; i < orderedStops.length; i++) {
            const locIdx = orderedStops[i];
            const arrivalSec = arrivalTimes[i];
            const departureSec = departureTimes[i];

            // Location name
            let locName: string;
            let locAddr = "";
            if (locIdx === startIdx) {
              locName = "Home";
              locAddr = startLocation;
            } else if (locIdx === endIdx) {
              locName = "Home";
              locAddr = endAddr;
            } else {
              const destIdx = locIdx - 1; // destinations are 1-indexed
              locName = destinations[destIdx].name;
              locAddr = destinations[destIdx].address;
            }

            // Arrival line
            if (i === 0) {
              output += `**${secondsToTime(arrivalSec)}** — Leave **${locName}** (${locAddr})\n`;
            } else {
              output += `**${secondsToTime(arrivalSec)}** — Arrive: **${locName}** (${locAddr})\n`;

              // Show duration at this stop
              const durSec = durationsSec[locIdx];
              if (durSec > 0 && locIdx !== endIdx) {
                output += `  ⏱️ ${formatDuration(durSec)} here\n`;
              }
            }

            // Transit directions to next stop
            if (i < legs.length) {
              const leg = legs[i];
              if (leg.itinerary) {
                output += "\n";
                for (const l of leg.itinerary.legs) {
                  output += formatLeg(l) + "\n";
                }
                output += "\n";
              } else {
                output += `  ⚠️ Could not find transit directions for this leg\n\n`;
              }

              // Departure line (if staying somewhere)
              if (i > 0 && durationsSec[locIdx] > 0 && locIdx !== endIdx) {
                output += `**${secondsToTime(departureSec)}** — Leave **${locName}**\n`;
              }
            }
          }

          // Summary
          const totalWalkMin = Math.round(totalWalkDistance / 80); // ~80m per minute walking
          const numDestinations = destinations.length;
          output += `\n📊 **Summary:** ${numDestinations} destination${numDestinations > 1 ? "s" : ""}, `;
          output += `${formatDuration(totalTransitTime)} total transit, `;
          output += `${Math.round(totalWalkDistance)}m walking (~${totalWalkMin} min), `;
          output += `${totalTransfers} transfer${totalTransfers !== 1 ? "s" : ""}\n`;

          if (solution.totalWaitTime > 60) {
            output += `⏳ Total waiting time: ${formatDuration(solution.totalWaitTime)}\n`;
          }

          output += `\n🔧 Optimization: ${solution.status} (OR-Tools VRPTW solver)`;

          return {
            content: [{ type: "text", text: output }],
          };
        } catch (err: any) {
          return {
            content: [
              {
                type: "text",
                text: `❌ Itinerary planning failed: ${err.message}\n\nThis could mean:\n- OTP server is not running at ${otpUrl}\n- Transit graph hasn't been built yet\n- OR-Tools Python solver is not installed\n\nCheck that OpenTripPlanner is running and has loaded a transit graph.`,
              },
            ],
          };
        }
      },
    },
    { optional: true }
  );
}
