
# Fusion Reactor Controller (ComputerCraft)

A compact ComputerCraft controller for the "Better Fusion Reactors" mod that automatically adjusts Control Rods (CR) and fuel injection to maximize efficiency while keeping reactor error and heat multiplier under control.

**Key goals:** reach ~100% efficiency, keep Error Level low, and search for an injection sweet-spot to minimize heat multiplier (HM).

**Features**
- Efficiency-driven, proportional-adaptive CR control with reversal cooldown to prevent oscillation
- Active injection sweet-spot search targeting a safe plasma temperature (~3200K)
- Adaptive step sizing (up to 50) for rapid large corrections and fine-tuning near target
- Safety locks and dampening when error is high
- Plain-text terminal UI for live telemetry

**Requirements**
- Minecraft with ComputerCraft (or CC: Tweaked) and the Better Fusion Reactors mod
- The reactor logic adapter peripheral accessible as the `bottom` peripheral (or update `peripheral.wrap` in the script)
- Place `reactorController.lua` on a ComputerCraft computer and run it from the computer.

Installation
- Copy `reactorController.lua` to your ComputerCraft advanced computer using "pastebin get RwYiFcpk reactorController.lua" inside of the advanced computer.
- Ensure the Reactor Logic Adapter is attached on the bottom side (or change the wrap side in the script).
- Start the controller with:

```bash
reactorController.lua
```

Usage
- The controller prints live telemetry (efficiency, error level, mode, direction, logic lock).
- Press any key in the terminal to stop the controller gracefully.

Configuration & Tuning
- `targetEff` (default `100`): Efficiency target the controller drives toward.
- `stepSize`, `minStep`, `maxStep`: Adaptive control step sizing for CR adjustments (default 8 / 1 / 50).
- `reversalCooldownMax` (default `2`): Number of cycles to hold after a direction reversal to avoid flip-flop.
- `targetPlasmaTemp` (default `3200` K): Temperature the injection search targets to reduce heat multiplier.
- `injectionLockCycles` (default `8`): How many stable cycles to wait before probing injection adjustments.

Tuning tips
- If the controller reacts too slowly to large TR shifts, increase `maxStep` slightly.
- If it oscillates at small errors, reduce `kp` or increase `reversalCooldownMax`.
- Lower `targetPlasmaTemp` if the mod's heat multiplier still climbs; watch case temperature trends.

Troubleshooting
- Strange reversals under extreme starts (e.g., CR=80, TR~0.6): this is an edge case where a large initial gap plus heat multiplier volatility can trigger reversal logic—try starting with CR closer to TR.
- Injection API requires even integers. The controller enforces this before calling `setInjectionRate`.
- If the reactor starts heating rapidly (case temp increases quickly), stop the controller and inspect HM behavior — the mod may be forcing a runaway independent of control logic.

Safety
- This controller cannot override mod-level Heat Multiplier mechanics. Rapid HM spikes can outpace any controller; monitor case temperature and be ready to shutdown.
- Always test with conservative `targetPlasmaTemp` and small `maxStep` values before increasing aggression.

Files
- Controller: [reactorController.lua](reactorController.lua)

License
- Suggested: MIT. Feel free to change to your preferred license.

Contact / Contributions
- Open an issue or PR with improvements, tunings, or UI tweaks.

Changelog
- Initial README created to document the controller behavior and tuning knobs.
