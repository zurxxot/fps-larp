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

## Settings

Constants at the top of `fps_larp.lua`:

| Name | Default | Meaning |
| --- | --- | --- |
| `VIRTUAL_FPS` | `400` | the frame rate callbacks are made to look like they run at |
| `MAX_STEPS` | `16` | most sub-steps per callback per frame |
| `EXTRA_MS` | `4` | most extra milliseconds per frame spent on sub-steps |
| `MAX_FRAME_SHARE` | `0.15` | the extra time is also capped at this share of the real frame time |
| `HOOK_RENDER_STEP` | `true` | set `false` to leave `BindToRenderStep` alone |
| `RESCAN_SECONDS` | `2` | how often existing connections are re-scanned |
| `DEBUG` | `false` | prints sub-step statistics every 2 seconds |

## Notes

- It does not raise your real FPS. Your screen still updates at your real frame rate; only the game's own Lua is stepped more often.
- Sub-stepping calls game code more times per frame, so a heavy game callback costs more. The budget settings above cap this, and if frames drop, lower `VIRTUAL_FPS` or `EXTRA_MS`.
- Use at your own risk. Hooking game functions can be detected and is against Roblox's terms.
