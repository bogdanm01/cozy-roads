# Cozy Roads

A warm, low-poly endless night-driving game built with Godot 4.7.

## Playable MVP

Start on the handling field, follow the scenic road, pull into the illuminated
roadside diner for a stamp, and continue through the glowing gateway onto a
deterministic endless road. Best trip distance and collected stamps persist
between launches.

The pickup uses custom weighty handling, terrain-aware body attitude, independent
visual suspension, acceleration squat, braking dive, steering roll, headlights,
brake lights, and procedural engine audio. The world includes a starry 9 PM sky,
fog, reflective road studs, forest scenery, ramps, grooves, guardrails, utility
lights, and a GPU-batched streaming road that recycles old chunks.

### Controls

- `W` / `Up`: accelerate
- `S` / `Down`: brake and reverse
- `A D` / arrow keys: steer
- Hold left mouse and drag: orbit the camera
- `R`: reset the car
- `M`: mute/unmute audio
- `O`: toggle higher-quality SSAO (more GPU intensive)
- Controller: left stick plus triggers

The HUD shows speed, steering angle, FPS, trip/best distance, route progress,
and the current objective.

## Performance

The default `FAST AO` mode targets at least 60 FPS at 2560×1440. The endless
section was measured at 99 FPS minimum on an Apple M1 Pro using the Compatibility
renderer. Road markings, reflectors, trees, and ambient-occlusion cards are
batched; endless chunks are capped at 12 active sections.

## Run

Open `project.godot` with Godot 4.7.1 or run:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path .
```
