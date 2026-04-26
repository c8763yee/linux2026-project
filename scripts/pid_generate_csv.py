#!/usr/bin/env python3
"""Generate PID controller simulation data as CSV.

Example:
  ./pid_generate_csv.py --output pid_data.csv
"""

from __future__ import annotations

import argparse
import csv
import sys
from dataclasses import dataclass


@dataclass
class PidState:
    integral: float = 0.0
    prev_error: float = 0.0


def simulate_pid(
    duration: float,
    dt: float,
    setpoint: float,
    kp: float,
    ki: float,
    kd: float,
    tau: float,
    u_min: float,
    u_max: float,
) -> list[dict[str, float]]:
    """Run a discrete PID loop on a first-order plant model."""
    state = PidState()
    y = 0.0
    rows: list[dict[str, float]] = []

    steps = int(duration / dt) + 1
    for i in range(steps):
        t = i * dt
        error = setpoint - y

        p_term = kp * error
        state.integral += error * dt
        i_term = ki * state.integral
        d_term = kd * (error - state.prev_error) / dt if i > 0 else 0.0

        u_raw = p_term + i_term + d_term
        u = max(u_min, min(u_max, u_raw))

        # First-order plant: dy/dt = (-y + u) / tau
        y += dt * ((-y + u) / tau)

        rows.append(
            {
                "t": t,
                "setpoint": setpoint,
                "measurement": y,
                "error": error,
                "p_term": p_term,
                "i_term": i_term,
                "d_term": d_term,
                "control": u,
            }
        )

        state.prev_error = error

    return rows


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate PID simulation CSV data")
    parser.add_argument("--output", default="pid_data.csv", help="Output CSV file")
    parser.add_argument(
        "--duration", type=float, default=20.0, help="Simulation time (s)"
    )
    parser.add_argument("--dt", "-t", type=float, default=0.05, help="Time step (s)")
    parser.add_argument(
        "--setpoint", "-s", type=float, default=1.0, help="Target value"
    )
    parser.add_argument("--kp", "-p", type=float, default=2.0, help="Kp")
    parser.add_argument("--ki", "-i", type=float, default=0.8, help="Ki")
    parser.add_argument("--kd", "-d", type=float, default=0.1, help="Kd")
    parser.add_argument("--tau", type=float, default=1.2, help="Plant time constant")
    parser.add_argument(
        "--u-min", type=float, default=-10.0, help="Control lower bound"
    )
    parser.add_argument("--u-max", type=float, default=10.0, help="Control upper bound")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    rows = simulate_pid(
        duration=args.duration,
        dt=args.dt,
        setpoint=args.setpoint,
        kp=args.kp,
        ki=args.ki,
        kd=args.kd,
        tau=args.tau,
        u_min=args.u_min,
        u_max=args.u_max,
    )

    fieldnames = [
        "t",
        "setpoint",
        "measurement",
        "error",
        "p_term",
        "i_term",
        "d_term",
        "control",
    ]

    with open(args.output, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
