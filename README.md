# Cozy Roads

A warm, low-poly endless driving game built with Godot 4.7.

## Playable MVP

Start directly on the scenic road, pull into the illuminated roadside diner for
a stamp, and continue through the glowing gateway onto a deterministic endless
road. Best trip distance and collected stamps persist between launches.

The pickup uses custom weighty handling, terrain-aware body attitude, independent
visual suspension, acceleration squat, braking dive, steering roll, headlights,
brake lights, and procedural engine audio. An eight-minute day/night cycle moves
from starry nights through warm dawn and dusk into clear daylight, continuously
blending the sky, sun, moon, fog, ambient light, and vehicle headlights. The
world includes reflective road studs, forest scenery, guardrails, utility
lights, and a GPU-batched streaming road that recycles old chunks. The opening
route climbs and descends through handcrafted hills, while generated terrain
continues into long rolling grades beyond the gateway. Catmull-Rom centerlines
keep the roads flowing through continuous bends; pavement, hillside collision,
traffic, markings, barriers, and roadside props all follow the same sampled
three-dimensional route.

Sparse two-way traffic shares both the scenic and endless roads. Five pooled
low-poly cars use separate lanes, varied cruising speeds, safe following gaps,
player-aware braking, headlights, and responsive brake lights without creating
or destroying nodes during play. The scenic route now passes a moonlit overlook,
timber-covered bridge, roadside diner, and warm forest cabin with a campfire;
streamed chunks add deterministic rocks and reflective wayfinding signs.

### Controls

- `W` / `Up`: accelerate
- `S` / `Down`: brake and reverse
- `A D` / arrow keys: steer
- Hold left mouse and drag: orbit the camera
- `R`: reset the car
- `T`: advance the clock by one hour
- `M`: mute/unmute audio
- `O`: toggle higher-quality SSAO (more GPU intensive)
- Controller: left stick plus triggers

The HUD shows the current time and day phase, speed, steering angle, FPS,
trip/best distance, route progress, and the current objective.

## Performance

The default `FAST AO` mode targets at least 60 FPS at 2560×1440. On an Apple M1
Pro using the Compatibility renderer, the illuminated scenic route with live
traffic measured 99.0 FPS average / 97 FPS minimum; the curved endless section
with traffic measured 96.2 FPS average / 87 FPS minimum. The daylight shadow
pass with rolling hill geometry measured 95.4 FPS average / 89 FPS minimum.
Road surfaces, hillside strips, markings,
reflectors, trees, rocks, and ambient-occlusion cards are batched; endless chunks
are capped at 12 active sections and traffic is capped at five pooled vehicles.

## Run

Open `project.godot` with Godot 4.7.1 or run:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path .
```
