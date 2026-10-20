# Netcode Design (`engine/net`)

Status: draft v2. Goal: small, readable, good enough for a 2–32 player action game.

## 1. Model in one paragraph

Every peer (server and clients) runs **the same `tick` proc** at a **fixed tick rate** on its
own copy of the game's `Game_State`. Each replicated entity has one **authority**: the server,
or the client that owns it. Every peer simulates everything, using the last known input for
remote players. When data arrives from an entity's authority, it **overwrites** the local copy.
The server sends each client a **delta-compressed snapshot**, relative to the last snapshot
that client acknowledged. Clients send their **input + owned entity state** every tick
(unreliable). **Gameplay events** (shots, hits, kills) are tick-stamped and ride inside those same
packets, so they line up with the state. **Messages** (chat, announcements) go reliably, untimed.
The server validates, applies, and relays.

This is client authority, not client-side prediction: no rollback, no replay, no reconciliation.

```
           Client A                          Server                           Client B
  ┌──────────────────────┐        ┌──────────────────────────┐        ┌──────────────────────┐
  │ recv → overwrite     │        │ recv → overwrite A's     │        │                      │
  │   non-owned state    │──in+───▶   owned fields (validated)│        │                      │
  │ tick(state, inputs)  │  state │ tick(state, inputs)      │        │                      │
  │ emit Hit{B} (in the  │        │ on_event: validate, dmg  │        │                      │
  │   next update)       │◀─snap──│ encode Δ + events        │──snap──▶ apply, fire events,  │
  │                      │        │                          │        │   extrapolate        │
  └──────────────────────┘        └──────────────────────────┘        └──────────────────────┘
```

## 2. What the game provides

The game owns its state. Struct tags mark what is replicated. Entity kinds are separate
structs stored in engine-provided pools.

```odin
// game/state.odin
Game_State :: struct {
    // tagged plain fields = replicated "globals"
    round_time:  f32                         `net:"q=0.05"`,
    scores:      [net.MAX_PLAYERS]i16        `net:""`,

    // tagged pools = replicated entity collections
    players:     net.Pool(Player, 32)        `net:""`,
    projectiles: net.Pool(Projectile, 256)   `net:""`,
    pickups:     net.Pool(Pickup, 64)        `net:""`,

    // untagged = local only, never touched by the engine
    particles:   [dynamic]Particle,
    camera:      Camera,
}

Player :: struct {
    pos:    [2]f32 `net:"q=0.01"`,
    vel:    [2]f32 `net:"q=0.01"`,
    aim:    f32    `net:"angle,bits=10"`,
    health: u8     `net:"server"`,    // server-authoritative even though the client owns the entity
    anim_t: f32,                      // local only
}

Projectile :: struct {
    pos: [2]f32 `net:"q=0.01"`,
    vel: [2]f32 `net:"q=0.1"`,
    shooter: net.Player_Id `net:""`,
}

Input :: struct {
    buttons: bit_set[Button; u16] `net:""`,
    move:    [2]i8                `net:""`,
    aim:     f32                  `net:"angle,bits=12"`,
}

Event   :: union { Shot, Hit, Interact, Kill }        // gameplay, tick-aligned
Message :: union { Chat, Round_Start, Round_End }     // meta, reliable, untimed
```

```odin
Game :: struct($S, $I, $V, $M: typeid) {
    // Advances the whole game one tick. Same proc on server and clients.
    // inputs[p] = live input for the local player, last known input for everyone else.
    tick:       proc(ctx: ^net.Context, s: ^S, inputs: ^[net.MAX_PLAYERS]I),

    // Server: event from a client, right after that client's state for the same tick. Validate it.
    // Client: event from the server, right after the snapshot carrying it is applied. Play effects.
    on_event:   proc(ctx: ^net.Context, s: ^S, from: net.Player_Id, ev: V),

    // Server: message from a client. Client: message from the server (`from` is NO_PLAYER).
    on_message: proc(ctx: ^net.Context, s: ^S, from: net.Player_Id, msg: M),

    // Server only: a player connected / disconnected. Spawn or remove their entity here.
    on_join:    proc(ctx: ^net.Context, s: ^S, p: net.Player_Id),
    on_leave:   proc(ctx: ^net.Context, s: ^S, p: net.Player_Id),
}
```

See section 11 for a full example.

The game makes an alias once: `Net_Client :: net.Client(Game_State, Input, Event, Message)`.

Inside `tick`, the game gates consequences with `ctx.is_server` (damage, spawns, score) and
can check `net.has_authority(ctx, pool, handle)` when needed. Moving a remote entity is always
allowed. It is just extrapolation, and the next authoritative update overwrites it.

## 3. Pools

```odin
Pool :: struct($T: typeid, $N: int) {
    items: [N]T,
    meta:  [N]Slot_Meta,
}

Slot_Meta :: struct {
    gen:      u16,         // incremented on reuse; a different gen means a new entity
    alive:    bool,
    owner:    Player_Id,   // NO_PLAYER = server authority
    override: u8,          // server bumps this to force-correct an owned entity (teleport, respawn)
}

Handle :: struct { index: u16, gen: u16 }

net.spawn(ctx, &s.projectiles, Projectile{...}, owner = NO_PLAYER) -> Handle   // server only
net.despawn(ctx, &s.projectiles, h)                                           // server only
net.get(&s.players, h) -> ^Player                                              // nil if stale
for &p, h in net.each(&s.players) { ... }                                     // alive slots
net.owner(&s.players, h) -> Player_Id
```

The schema builder recognizes `net.Pool` through reflection (`items` + `meta: [N]Slot_Meta`).
Pools may appear anywhere in `Game_State` that is tagged, including nested structs.

## 4. Field authority

* Entity owned by the **server**: the server writes all fields.
* Entity owned by a **client**: the client writes all fields **except** `net:"server"` fields.
  The client sends only owner fields. The server sends everything. The owning client applies
  only the server fields from snapshots (and everything if `override` changed).
* Globals: always server.

This is how `health` lives on the player's entity without the player being able to set it.

## 5. Struct tags → schema

At startup `net.build_schema(typeid_of(S))` walks the type with `core:reflect` and produces
sections: one **globals** section (all tagged non-pool leaf fields, flattened) and one section
per **pool**. After startup no reflection runs.

```odin
Field :: struct {
    offset:    uintptr,
    kind:      enum { Bool, Int, Uint, Float_Quant, Float_Raw, Angle },
    bits:      u8,
    q:         f32,
    authority: enum { Owner, Server },
}
Section :: struct { offset: uintptr, stride: int, count: int, fields: []Field, is_pool: bool }
Schema  :: struct { sections: []Section, hash: u64 }
```

| tag                  | meaning                                      |
|----------------------|----------------------------------------------|
| `net:""`             | replicate with default encoding for its type |
| `net:"q=0.01"`       | float → int at 0.01 precision, varint        |
| `net:"bits=N"`       | int/uint packed into N bits                  |
| `net:"angle,bits=N"` | float radians wrapped into N bits            |
| `net:"raw"`          | full 32-bit float                            |
| `net:"server"`       | server-authoritative field (combinable: `"q=0.1,server"`) |
| *(no tag)*           | not replicated                               |

Supported: ints, floats, bool, enums, `bit_set`, fixed arrays (each element is a leaf), nested
structs (flattened), `net.Pool`. Unions are only used for events and messages (variant index,
then the variant's fields). `string` is allowed in event and message variants only, since those are
sent in full rather than diffed. Received strings live in `context.temp_allocator`, so copy any you keep.
Slices, maps, pointers, and dynamic arrays inside tagged fields are a schema-build error.
The schema hash is checked in the connect handshake, so mismatched builds cannot connect.
The same builder handles `Input` and each `Event` and `Message` variant.

## 6. Snapshots & delta compression

A **snapshot** is the replicated part of the state captured as a flat array of quantized
integers, one per (section, slot, field), plus the slot meta. This keeps snapshots independent
of game memory (no copying dynamic arrays). It also means all diffs compare quantized values,
so float noise below the precision costs nothing.

```
snapshot (flat array of quantized values)
├── globals:          every tagged leaf field on Game_State (nested structs/arrays flattened)
├── inputs:           last input per player
├── pool players:     [meta + fields] × N
├── pool projectiles: [meta + fields] × N
└── ...
```

* The server keeps a ring of the last 64 snapshots, indexed by tick.
* Each client sends `ack_tick` (the newest snapshot it received) in every packet.
* The server encodes the current snapshot **against that client's acked snapshot**. If the ack
  is missing or too old, it encodes against zero, which gives a full snapshot.
* The client keeps the same ring of received snapshots for decoding.

Encoding, per section:

```
for each slot that differs from baseline:
    write index delta (varint)
    write state: 2 bits {removed, spawned (new gen → baseline is zero), changed}
    write changed-field bitmask (1 bit per field)
    write changed fields
write end marker
```

Also replicated in every snapshot: the engine's `Player_Table(Input)`, a `Pool(Input, MAX_PLAYERS)`
where slot = player id and alive = connected. It is registered as a second schema root
(`schema_append`), so inputs get the same delta compression and ride in the same snapshot.
Clients use these inputs to extrapolate remote players.

## 7. Packets

Every packet starts with an 8-bit `Message_Kind` (see `protocol.odin`).

| message | dir | channel | contents |
|---|---|---|---|
| Hello | C→S | reliable | protocol hash (state + input + event + message layouts). Mismatch → kicked |
| Welcome | S→C | reliable | player id, tick rate, server tick |
| Client_Update | C→S | unreliable | client tick, acked snapshot tick, input, owned entities (owner fields only), events |
| Snapshot | S→C | unreliable | server tick, baseline tick, echoed client tick, Δsnapshot, events |
| Message | both | reliable | message |

Owned entities go in full (quantized) every tick. They are small, and this avoids a second ack system.
Each owned entity carries its `gen` and `override`. The server ignores it if either is stale.

### Events vs messages

| | **Events** (`emit`) | **Messages** (`send`) |
|---|---|---|
| For | gameplay: Shot, Hit, Kill, Explosion | meta: Chat, Round_Start, Round_End, notices |
| Rides in | Snapshot / Client_Update (unreliable) | its own reliable, ordered packet |
| Timing | tick-stamped; fired right after the matching state | whenever it arrives |
| Delivery | resent until acked or TTL expires; receiver drops duplicates | guaranteed |
| Sent from | game callbacks (or a ^Client between ticks) | anywhere: `ctx`, `^Client`, `^Server` |

**How events survive loss.** Each sender keeps an event log. Every packet repeats the events the
other side hasn't confirmed:
- server → client: events with tick > the client's acked snapshot tick
- client → server: events with tick > the client tick the server last echoed

An event is stamped with the tick of the **first packet that carries it**: the current tick inside a
tick, or the next tick when emitted between ticks. That way "acked up to tick N" really means
"has everything stamped ≤ N". Each event has an increasing id, and receivers skip ids they've seen.

**TTL.** `Config.event_ttl` (default 1 s) is how long an event is resent. Per emit,
`ttl = 0.25` overrides it, `ttl = 0` means "only in the next packet", and `ttl = net.FOREVER`
resends it until acked. A cosmetic muzzle flash that's 2 s late is worse than none, while a kill
should always arrive.

**Order on the client.** Snapshot received → events queued → next tick: apply the snapshot, then
fire its events, then run `tick`. If several snapshots arrive between ticks, only the newest state
is applied, but every event from all of them fires, in order.

**Order on the server.** For each Client_Update: input, then owned entities, then events. A
client's `Hit` is validated against that client's position from the same tick.

Prefer **state** for anything a late joiner needs. For example, `round_phase` and `round_timer`
are tagged fields, and Round_Start / Round_End messages are just the announcement.

## 8. Tick loops

Fixed timestep (default 60 Hz). `update(frame_dt)` accumulates time and runs 0..n ticks.
Both loops have the same shape: **receive → apply authoritative data → tick → send**.

**Server**
1. Receive. For each client packet that is newer than the last one from that client: store its input.
   If its `override` matches, copy its owner fields into its entities, after the pool's `server_validate` check
   (max speed, inside the map).
   Then the update's new events → `on_event`. Reliable messages → `on_message`.
2. `tick(ctx, s, inputs)`. Players with no new packet keep their last input, so the server extrapolates them too.
3. Capture snapshot → ring. For each client: encode Δ against its ack, append its unacked events, send.
4. Drop events that expired or that every recipient acked.
5. After all ticks of the update: send queued messages.

**Client**
1. Receive. Decode newer snapshots into the ring, queue their new events, and drop own events the
   server echoed. Messages → `on_message` immediately.
2. Tick. If a newer snapshot was received: write it into `Game_State`, then fire its queued events.
   Non-owned entities get all fields. Owned entities get only server fields, or all fields on `override`.
   Spawned or removed slots are applied. Remote inputs are updated.
3. `inputs[local] = sample_input()`, then `tick(ctx, s, inputs)`. Remote entities extrapolate from
   the snapshot state with their last input.
4. Send input + owned fields + ack + unacked events. After all ticks: send queued messages.

There is no clock sync. Ticks only order packets and measure RTT. Nothing rewinds, so the
client and server ticks don't need to line up.

Remote players render roughly half an RTT behind their true position. That is the cost of not
replaying. A later option is `net:"smooth"` on fields, so corrections blend over a few frames instead of snapping.

## 9. Client-authoritative actions

* **Movement:** the client simulates it. The server sanity-checks it. Everyone else extrapolates it.
* **Shooting:** the client does the hit test against what it sees, then sends `Shot{origin, dir}` + `Hit{target}`.
  The server's `on_event` checks fire rate, range, line of sight, and that the target is alive, then changes `health`.
  The shooter plays effects immediately. The server relays `Shot` to everyone except the origin.
* **Interactions:** `Interact{target}` → the server checks → changes the state → snapshot.

Rule of thumb: **clients own their body and their claims. The server owns consequences.**

## 10. Context

```odin
Context :: struct {
    tick:         Tick,
    dt:           f32,
    is_server:    bool,
    local_player: Player_Id,  // NO_PLAYER on the server
    // internal: event log, message queue, schemas
}

// Events: `ev` is the Event union or one variant. `ttl` is optional (seconds, 0, or net.FOREVER).
net.emit(ctx, ev, ttl = ...)              // client → server; server → all
net.emit_to(ctx, player, ev, ttl = ...)   // server only
net.emit_except(ctx, player, ev)          // server only (relay)

// Messages: the first argument can be a ctx, a ^Client or a ^Server.
net.send(ctx | &cl | &srv, msg)           // client → server; server → all
net.send_to(ctx | &srv, player, msg)      // server only
net.send_except(ctx | &srv, player, msg)  // server only
```

The sender's own `on_event` / `on_message` is not called, so play local effects directly.

## 11. Game API (full example)

### Types

```odin
package game

import "engine:net"

Game_State :: struct {
    round_time:    f32                          `net:"q=0.05"`,
    scores:        [net.MAX_PLAYERS]i16         `net:""`,
    player_entity: [net.MAX_PLAYERS]net.Handle  `net:""`,   // handles are replicable

    players:     net.Pool(Player, net.MAX_PLAYERS) `net:""`,
    projectiles: net.Pool(Projectile, 256)         `net:""`,

    tracers: [dynamic]Tracer,   // local only
}

Player :: struct {
    pos:      [2]f32 `net:"q=0.01"`,
    vel:      [2]f32 `net:"q=0.01"`,
    aim:      f32    `net:"angle,bits=10"`,
    health:   u8     `net:"server"`,
    cooldown: f32,               // local only
}

Shot :: struct { origin: [2]f32 `net:"q=0.01"`, dir: f32 `net:"angle,bits=12"` }
Hit  :: struct { target: net.Handle `net:""` }
Kill :: struct { killer, victim: net.Player_Id `net:""` }
Event   :: union { Shot, Hit, Kill }
Message :: union { Chat }                    // Chat :: struct { from: net.Player_Id `net:""`, text: string `net:""` }

Net_Server :: net.Server(Game_State, Input, Event, Message)
Net_Client :: net.Client(Game_State, Input, Event, Message)
```

### Hooks

```odin
make_game :: proc() -> net.Game(Game_State, Input, Event, Message) {
    return {tick = tick, on_event = on_event, on_message = on_message, on_join = on_join, on_leave = on_leave}
}

tick :: proc(ctx: ^net.Context, s: ^Game_State, inputs: ^[net.MAX_PLAYERS]Input) {
    it := net.iter(&s.players)
    for p, h in net.next(&it) {
        o := net.owner(&s.players, h)
        if o == net.NO_PLAYER do continue          // inputs are only indexed by real players
        input := inputs[o]
        move_player(p, input, ctx.dt)                 // runs for everyone: local, remote, server

        if net.is_mine(ctx, &s.players, h) {       // only the owner decides to shoot
            p.cooldown -= ctx.dt
            if .Fire in input.buttons && p.cooldown <= 0 do fire(ctx, s, h, p)
        }
    }

    pit := net.iter(&s.projectiles)
    for pr, h in net.next(&pit) {
        pr.pos += pr.vel * ctx.dt                  // clients extrapolate, server decides
        if ctx.is_server && hit_wall(pr.pos) do net.despawn(ctx, &s.projectiles, h)
    }

    if ctx.is_server do s.round_time -= ctx.dt
}

fire :: proc(ctx: ^net.Context, s: ^Game_State, h: net.Handle, p: ^Player) {
    p.cooldown = 0.15
    net.emit(ctx, Shot{p.pos, p.aim})
    spawn_tracer(s, p.pos, p.aim)                  // instant local feedback
    if target, ok := raycast_players(s, p.pos, p.aim, ignore = h); ok {
        net.emit(ctx, Hit{target})                 // client-authoritative claim
    }
}

on_event :: proc(ctx: ^net.Context, s: ^Game_State, from: net.Player_Id, ev: Event) {
    switch e in ev {
    case Shot:
        if ctx.is_server do net.emit_except(ctx, from, e)   // relay to others
        else do spawn_tracer(s, e.origin, e.dir)
    case Hit:
        if !ctx.is_server do return
        shooter := net.get(&s.players, s.player_entity[from]) or_return
        target  := net.get(&s.players, e.target) or_return
        if !plausible_hit(s, shooter, target) do return     // range, LOS, fire rate
        target.health = sat_sub(target.health, 25)
        if target.health == 0 {
            s.scores[from] += 1
            respawn(ctx, s, e.target)
            net.emit(ctx, Kill{from, net.owner(&s.players, e.target)}, ttl = net.FOREVER)
        }
    case Kill:
        show_killfeed(e)
    }
}

on_message :: proc(ctx: ^net.Context, s: ^Game_State, from: net.Player_Id, msg: Message) {
    switch m in msg {
    case Chat:
        if ctx.is_server do net.send(ctx, Chat{from = from, text = m.text})  // stamp the real sender, relay
        else do add_chat_line(s, m.from, m.text)                            // m.text is temp memory: copy it
    }
}

// From UI code, outside any callback:
//     net.send(&cl, Chat{text = input_box_text})

on_join :: proc(ctx: ^net.Context, s: ^Game_State, p: net.Player_Id) {
    s.player_entity[p] = net.spawn(ctx, &s.players, Player{pos = spawn_point(s), health = 100}, owner = p)
}

on_leave :: proc(ctx: ^net.Context, s: ^Game_State, p: net.Player_Id) {
    net.despawn(ctx, &s.players, s.player_entity[p])
    s.player_entity[p] = {}
}

respawn :: proc(ctx: ^net.Context, s: ^Game_State, h: net.Handle) {
    p := net.get(&s.players, h)
    p^ = Player{pos = spawn_point(s), health = 100}
    net.force_sync(ctx, &s.players, h)   // bumps `override`: the owner must accept the server's state
}

// Server check on owner-written fields arriving from a client.
validate_player :: proc(ctx: ^net.Context, from: net.Player_Id, old, new: ^Player) -> bool {
    return linalg.length(new.pos - old.pos) <= MAX_SPEED * ctx.dt * 3
}
```

### Entry points

The server and client take a `Transport` and destroy it in `server_stop` / `client_stop`.

```odin
run_server :: proc(port: u16) {
    transport, ok := net.enet_host(port)          // enet_host(port, "127.0.0.1") to stay local
    if !ok do panic("could not open port")
    state: Game_State
    srv: Net_Server
    if err := net.server_start(&srv, &state, make_game(), transport); err != "" do panic(err)
    net.server_validate(&srv, &state.players, validate_player)
    defer net.server_stop(&srv)
    for !quit do net.server_update(&srv, frame_dt())   // recv → tick 0..n times → send
}

run_client :: proc(addr: string, port: u16) {
    transport, ok := net.enet_connect(addr, port)
    if !ok do panic("could not resolve address")
    state: Game_State
    cl: Net_Client
    if err := net.client_start(&cl, &state, make_game(), transport); err != "" do panic(err)
    defer net.client_stop(&cl)
    for !glfw.WindowShouldClose(window) {
        net.client_update(&cl, frame_dt(), sample_input())
        switch net.status(&cl) {
        case .Connecting:   draw_connecting()
        case .Connected:    render(&state, net.local_player(&cl), net.alpha(&cl))
        case .Disconnected: draw_disconnected()
        }
    }
}

// Listen server: two separate states in one process, connected over loopback.
run_host :: proc() {
    lb: net.Loopback
    net.loopback_init(&lb)                         // or {lag = 0.075, loss = 0.05} to test bad networks
    defer net.loopback_destroy(&lb)

    server_state, client_state: Game_State
    srv: Net_Server
    cl:  Net_Client
    net.server_start(&srv, &server_state, make_game(), net.loopback_server(&lb))
    net.client_start(&cl, &client_state, make_game(), net.loopback_client(&lb))
    defer net.server_stop(&srv)
    defer net.client_stop(&cl)
    for !glfw.WindowShouldClose(window) {
        dt := frame_dt()
        net.server_update(&srv, dt)
        net.client_update(&cl, dt, sample_input())
        render(&client_state, net.local_player(&cl), net.alpha(&cl))
    }
}
```

### Surface

| Area | API |
|---|---|
| Setup | `Game{tick, on_event, on_message, on_join, on_leave}`, `Config{tick_rate, snapshot_every, max_catchup, event_ttl}` |
| Server | `server_start`, `server_update`, `server_stop`, `server_validate(pool, proc)`, `kick` |
| Client | `client_start`, `client_update(dt, input)`, `client_stop`, `status`, `local_player`, `ping`, `alpha`, `player_connected` |
| Transport | `enet_host(port, bind_address)`, `enet_connect(address, port)`, `loopback_init/_server/_client/_destroy` |
| Pools | `spawn`, `despawn`, `get`, `iter`/`next`, `owner`, `is_mine`, `has_authority`, `force_sync` |
| Events | `emit`, `emit_to`, `emit_except` (optional `ttl`, `FOREVER`) |
| Messages | `send`, `send_to`, `send_except` (ctx, ^Client or ^Server) |
| Context | `ctx.tick`, `ctx.dt`, `ctx.is_server`, `ctx.local_player` |

## 12. Package layout

```
engine/net/
  net.odin         MAX_PLAYERS, Tick, Player_Id
  bits.odin        bit writer/reader, varint, zigzag
  field.odin       capture/restore/read/write one field (quantization)
  schema.odin      reflect + tags → Schema (sections, fields)
  snapshot.odin    capture/apply snapshot ↔ state, ring buffer
  delta.odin       encode/decode snapshot against a baseline
  pool.odin        Pool, Handle, get/iter/next/owner
  events.odin      union schemas (events + messages), event log + wire format, message queue
  context.odin     Game, Config, Context, emit*, send*, spawn/despawn/force_sync
  protocol.odin    message kinds, owned-entity encoding, Player_Table, Core (shared by server and client)
  transport.odin   Transport interface
  loopback.odin    in-process Transport with fake lag/jitter/loss
  enet.odin        ENet Transport (vendor:ENet): enet_host, enet_connect
  server.odin      Server(S, I, V)
  client.odin      Client(S, I, V)
```

Only `enet.odin` imports ENet. The loopback transport gives a listen server / singleplayer
(client and server in one process) and headless tests in `tests/` with simulated lag and loss.

## 13. Left out of v1

* Bandwidth budget / priority / relevancy. Add when snapshots exceed ~1200 bytes.
* Client-spawned entities (e.g. predicted projectiles). In v1 the server spawns them, and the shooter shows a local cosmetic.
* Server rewind / lag compensation. Not needed with client-authoritative hits.
* Correction smoothing (`net:"smooth"`).
* Encryption / auth.

## 14. Build order

1. ✅ `bits` + `schema` + `snapshot` + `delta`, with round-trip unit tests (no networking).
2. ✅ `pool` + loopback transport + server/client loops, tested headless in one process.
3. ✅ ENet transport, tested over localhost UDP.

Run the tests with `odin test tests/net -collection:engine=engine`.
4. ✅ Demo in `game/`: squares moving and shooting (host / server / client / selftest), see readme.
