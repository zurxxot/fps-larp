# fps larp

A Roblox client script that makes a game's per-frame Lua look like it is running at a much higher frame rate (400 "virtual" FPS by default) without changing your real FPS.

It hooks the game's `Heartbeat` / `RenderStepped` / `Stepped` / `PreRender` / `PreAnimation` / `PreSimulation` / `PostSimulation` callbacks, `BindToRenderStep` bindings, `task.wait()` / `RunService.X:Wait()` loops and the game's `HeartbeatLoopFor` helper, and runs each of them several times per real frame with a proportionally smaller `dt`. Effects driven by those callbacks come out smoother. A per-frame time budget stops it from costing you real frames.

It also redraws the Skypiean race aura trail with a pool of beams, so that trail is drawn at the virtual frame rate too.

**Made for Blox Fruits.** The generic sub-stepping works in any game, but the aura redraw and the excluded-script list (`EffectContainer`, `Util.HeartbeatLoopFor`, ...) are Blox Fruits specific. Elsewhere those parts simply find nothing and stay idle.

## What your executor needs

The script uses these executor functions. Without something from the first group it errors, breaks game code, or does very little. The second group degrades gracefully.

**Required**

| Function | Used for |
| --- | --- |
| `getgenv` | keeping state between runs, re-running cleanly, the `FpsLarp()` unload function |
| `hookmetamethod` | hooking `__index` on frame signals (`RBXScriptSignal`, not just Instances) and `__namecall` on `game`. The script still loads without it, but only connections that already existed are caught, so most of the effect is gone |
| `hookfunction` | hooking `task.wait`, the game's `HeartbeatLoopFor` module functions (a missing `hookfunction` errors on load in Blox Fruits), and the Lua functions behind existing connections. It has to work on **Lua closures**, not only C functions |
| `newcclosure` | wrapping the hook functions |
| `checkcaller` | telling the executor's own calls apart from the game's, inside the hooks |
| `getnamecallmethod` | reading the method name in the `__namecall` hook (`BindToRenderStep` / `UnbindFromRenderStep`) |

**Optional (the script prints a warning or silently skips that part)**

| Function | What you lose without it |
| --- | --- |
| `getconnections` | connections made before you ran the script are not sub-stepped. It also needs the returned connections to expose `.Function`, `.LuaConnection`, `.ForeignState` and `.Enabled` |
| `islclosure` | same as above, because it decides which connection functions can be hooked |

**Also needed, not executor functions**

- `debug.info(level_or_function, "s")` returning the full script path for game scripts (the engine provides this, the executor just must not remove or replace it)
- `require` working on game ModuleScripts from the executor thread
- Running on the client after `Players.LocalPlayer` exists
- `game:HttpGet` and `loadstring`, only if you want the one-line loader below instead of pasting the file

Written on Volt; not tested on other executors.

### Quick check

Paste this into your executor first. Anything that prints `MISSING` is a problem.

```lua
for _, f in ipairs({
    { "getgenv", getgenv }, { "hookmetamethod", hookmetamethod }, { "hookfunction", hookfunction },
    { "newcclosure", newcclosure }, { "checkcaller", checkcaller }, { "getnamecallmethod", getnamecallmethod },
    { "getconnections", getconnections }, { "islclosure", islclosure }, { "debug.info", debug.info },
}) do
    print(f[1], f[2] and "ok" or "MISSING")
end
```

## Use

Paste `fps_larp.lua` into your executor and run it in-game, or:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/zurxxot/fps-larp/main/fps_larp.lua"))()
```

Running it again replaces the previous run. To turn it off:

```lua
getgenv().FpsLarp()
```

## Changing the virtual FPS

Open `fps_larp.lua` and edit the first settings at the top:

```lua
local VIRTUAL_FPS = 400
local MAX_STEPS = 16
```

Then run the file again. A new run replaces the old one, so there is no need to unload first.

If you use the one-line loader, you can't edit the file, so change the numbers before it runs:

```lua
local src = game:HttpGet("https://raw.githubusercontent.com/zurxxot/fps-larp/main/fps_larp.lua")
src = src:gsub("local VIRTUAL_FPS = %d+", "local VIRTUAL_FPS = 240")
src = src:gsub("local MAX_STEPS = %d+", "local MAX_STEPS = 8")
loadstring(src)()
```

Setting `VIRTUAL_FPS` at or below your real FPS does nothing, because every callback already runs at least once per frame.

## Choosing MAX_STEPS

Each real frame, a callback is run `VIRTUAL_FPS / real FPS` times, each time with a proportionally smaller `dt`. `MAX_STEPS` is the most times it is allowed to run in one frame. So set it to at least:

```
MAX_STEPS = ceil(VIRTUAL_FPS / the lowest real FPS you still want fully covered)
```

This table shows the steps needed (rounded up):

| VIRTUAL_FPS | real 30 | real 60 | real 120 | real 144 | real 240 |
| --- | --- | --- | --- | --- | --- |
| 120 | 4 | 2 | no effect | no effect | no effect |
| 240 | 8 | 4 | 2 | 2 | 1 |
| 400 | 14 | 7 | 4 | 3 | 2 |
| 600 | 20 | 10 | 5 | 5 | 3 |
| 1000 | 34 | 17 | 9 | 7 | 5 |

Reading it: at 60 real FPS, the default `VIRTUAL_FPS = 400` needs 7 steps per frame, so the default `MAX_STEPS = 16` has room to spare. The defaults only cover 400 virtual FPS down to about 25 real FPS (`400 / 16`). Below that the virtual FPS falls to `MAX_STEPS` times your real FPS.

- If the ratio is not a whole number, the count alternates between the two neighbouring values (for example 6 and 7 at 60 real FPS). A `VIRTUAL_FPS` that is a multiple of your real FPS gives the same count every frame.
- A bigger `MAX_STEPS` than you need changes nothing at your normal FPS. It only matters when your real FPS dips, where it allows more steps per frame. A smaller one limits the virtual FPS you get during those dips.

### The time budget is the real limit

`MAX_STEPS` only says how many steps are allowed. The steps that actually run are limited by the time budget, which is the smaller of `EXTRA_MS` and `MAX_FRAME_SHARE` of one frame:

| real FPS | budget per frame |
| --- | --- |
| 30 | 4 ms (`EXTRA_MS` caps it) |
| 60 | 2.5 ms |
| 144 | about 1 ms |
| 240 | about 0.6 ms |

When the budget runs out, the remaining steps are skipped for that frame and the last call gets the leftover `dt`. Raising `VIRTUAL_FPS` and `MAX_STEPS` alone won't help if the game's callbacks are heavy.

To check, set `DEBUG = true`. Every 2 seconds it prints `sub-steps ran N, skipped N | waits boosted N, denied N | budget X ms/frame`.

- `skipped` is small next to `ran`: the settings fit. You could try a higher `VIRTUAL_FPS`.
- `skipped` is large: lower `VIRTUAL_FPS`, or raise `EXTRA_MS` / `MAX_FRAME_SHARE`. That spends real frame time, so your actual FPS can drop.

Very high `VIRTUAL_FPS` also makes the aura redraw build more beams. Its beam pool grows with `VIRTUAL_FPS` times the trail's lifetime, up to 2000 beams per trail.

## Settings

Constants at the top of `fps_larp.lua`:

| Name | Default | Meaning |
| --- | --- | --- |
| `VIRTUAL_FPS` | `400` | the frame rate callbacks are made to look like they run at |
| `MAX_STEPS` | `16` | most sub-steps per callback per frame, see [Choosing MAX_STEPS](#choosing-max_steps) |
| `EXTRA_MS` | `4` | most extra milliseconds per frame spent on sub-steps |
| `MAX_FRAME_SHARE` | `0.15` | the extra time is also capped at this share of the real frame time. At about 37 real FPS and above this is the cap that applies, not `EXTRA_MS` |
| `HOOK_RENDER_STEP` | `true` | set `false` to leave `BindToRenderStep` alone |
| `RESCAN_SECONDS` | `2` | how often existing connections are re-scanned |
| `DEBUG` | `false` | prints sub-step statistics every 2 seconds |

## Notes

- It does not raise your real FPS. Your screen still updates at your real frame rate; only the game's own Lua is stepped more often.
- Sub-stepping calls game code more times per frame, so a heavy game callback costs more. The budget settings above cap this, and if frames drop, lower `VIRTUAL_FPS` or `EXTRA_MS`.
- Use at your own risk. Hooking game functions can be detected and is against Roblox's terms.
