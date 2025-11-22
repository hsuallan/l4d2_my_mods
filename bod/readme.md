# L4D2 Breath of Divinity (Dawn Shield)

This SourceMod plugin brings the famous **Breath of Divinity (BoD)** skill from Maplestory into Left 4 Dead 2. It grants Survivors a temporary "Second Life" shield that absorbs damage and regenerates when attacking enemies.

## 🌟 Features

*   **Protective Shield:** Creates a second HP bar (Purple) that takes damage before your real health does.
*   **Lifesteal:** Attacking Zombies or Special Infected regenerates your Shield HP.
*   **One-Shot Protection:** If a massive attack hits you (e.g., Tank rock) while the shield is active, the shield breaks, but you take **0 damage** to your real HP.
*   **Visuals:** Your screen tints purple while the shield is active.
*   **HUD:** Displays Shield HP and remaining duration in the center of your screen.

## 📥 Installation

1.  **Prerequisites:** Ensure you have **SourceMod** and **Metamod:Source** installed on your server.
2.  **Compile:**
    *   Save the plugin code as `l4d2_bod.sp`.
    *   Drag and drop it onto `spcomp.exe` (located in your `sourcemod/scripting` folder) to create `l4d2_bod.smx`.
3.  **Upload:**
    *   Place `l4d2_bod.smx` into your server's `addons/sourcemod/plugins/` folder.
4.  **Load:**
    *   Restart your server or type `sm plugins load l4d2_bod` in the console.

## 🎮 How to Use

*   **Activate:** Press your **RELOAD Key (Default: R)**.
    *   *Note: You must be a Survivor.*
*   **Combat:**
    *   While active, damage is subtracted from the Shield first.
    *   Keep shooting/meleeing zombies to keep your Shield HP full!
    *   The shield naturally decays over time.
*   **Cooldown:** If you press R while on cooldown, the chat will tell you how many seconds are left.

## ⚙️ Configuration (ConVars)

A config file will be automatically generated at `cfg/sourcemod/l4d2_bod.cfg`. You can edit these values:

| ConVar | Default | Description |
| :--- | :--- | :--- |
| `bod_max_hp` | `100` | Maximum HP of the Dawn Shield. |
| `bod_duration` | `60.0` | How long the shield lasts (in seconds). |
| `bod_cooldown` | `60.0` | Cooldown time before you can use it again. |
| `bod_decay_rate` | `2` | How much Shield HP is lost automatically per second. |
| `bod_lifesteal` | `5` | How much Shield HP you recover per hit on an enemy. |

## 📝 Version History

*   **1.0** - Initial Release.