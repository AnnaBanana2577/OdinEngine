# OdinEngine

A small multiplayer game engine in Odin (GLFW, OpenGL, ENet, stb).

- `engine/net`: netcode. The game owns its state and marks replicated fields with `net` struct tags. The engine sends delta-compressed snapshots, and clients are authoritative over their own entities. Design: [docs/netcode.md](docs/netcode.md).
- `game/`: demo. Squares that move and shoot.
- `tests/`: headless tests.

## Build and run

```
odin build game -collection:engine=engine -out:build/demo.exe
```

```
build\demo.exe host                                  # you + 3 bots, server in-process
build\demo.exe host -bots=5 -lag=100 -jitter=20 -loss=5   # same, over a bad fake network
build\demo.exe server -port=7777                     # dedicated UDP server
build\demo.exe client -addr=127.0.0.1 -port=7777     # join it
build\demo.exe selftest -lag=75 -loss=10             # headless bots; checks everyone ends in sync
```

Controls: WASD or arrow keys to move, mouse to aim, left click or space to shoot. Window title shows player id, score and ping.

## Tests

```
odin test tests/net -collection:engine=engine
```
