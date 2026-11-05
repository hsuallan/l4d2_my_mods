# Left 4 Dead 2 AI 動態導演系統技術規格書 (System Specification)

* **文件版本**：v1.2.0 (Multi-Survivor DDA & MVP Focus Strike Revision)
* **目標受眾**：後續接手實作之開發團隊與外包工程師
* **目標系統**：Left 4 Dead 2 Dedicated Server (SRCDS) + SourceMod 1.12 + 外部 AI 決策微服務
* **核心依賴**：[`Left 4 DHooks Direct (v1.174+)`](https://forums.alliedmods.net/showthread.php?t=321696)、[`REST in Pawn (rip.ext)`](https://forums.alliedmods.net/showthread.php?t=298024)（或 `sm-ext-websocket`）、[L4D2 VScript `DirectorOptions`](https://developer.valvesoftware.com/wiki/Left_4_Dead_2/Scripting/Director_Scripts)
* **適用玩家生態**：**4 ～ 10 人多人生還者伺服器（Multi-Slot Server）**，具備不對稱多特感強度與動態難度自適應（DDA）

---

## 1. 專案背景與核心設計哲學 (Design Philosophy & ADR)

### 1.1 核心定位：多人生態、張馳有度、不壞地圖、斬首特攻
本專案**以 4～10 人多人生還者遊玩為基準目標**。傳統多特伺服器（如 `l4dinfectedbots`）雖能增加特感數量，但由於其採用死板的固定計時器且機械式硬塞怪，經常造成「剛打完怪要救人就被團滅」的垃圾難度死鎖，或是「一出 Tank 就停止刷特感」的割裂感。

本 AI 動態導演系統的核心哲學為：
1. **多人生態不對稱性（Asymmetric Scaling）**：
   * **特感活體總數基準永遠維持在「存活生還者人數 + 2」**（4 人局出 6 特、8 人局出 10 特、10 人局出 12 特）。
2. **張馳有度的波次節奏感（Wave-Based Pacing, 不完全簡單也不完全困難）**：
   * 嚴禁無腦逐隻偷生（Trickle Spawn）。全隊特感以**「同步波次（Synchronized Wave）」**集體進攻與伏擊。
   * 兩波進攻之間必須給予適當的**「安全換氣期」**（考量扶人 5s、打包 5s、裝彈 3s 的物理時間成本），依 AI 動態難度調控在 **20s ～ 50s** 之間浮動。
3. **兵種防自閉機制（Anti-Hard-CC Spam）**：
   * 單一控場特感（Charger/Hunter/Jockey/Smoker）在場數量**嚴格限制不得超過生還者人數的 1/3**，確保混戰體驗豐富，絕不出現全隊被 5 隻 Charger 撞爛秒滅的無效挫折。
4. **MVP 核心玩家特攻隊（MVP Focus Strike, 最多 1/2 特感組隊）**：
   * 透過 Left 4 DHooks Direct 鎖定團隊中輸出最高、拯救隊友最多或走位最激進的「最有影響力玩家（MVP）」。
   * **本地守門員嚴格限制：特攻小隊最多只能指派 $\le 1/2$ 活體特感**（例如場上 10 隻特感，最多 5 隻鎖定 MVP；其餘 $\ge 1/2$ 特感必須分流牽制其他生還者），既給予 Carry 玩家頂級壓迫感，又保留隊友救援反打的協作空間。
5. **Tank 高壓混戰體驗**：
   * Tank 血量動態公式化（基準 $5000 + n \times \text{生還者人數}$），並順應時機一次出 2 隻、3 隻或更多。
   * **Tank 出現時特感持續刷新**，逼迫玩家在風箏 Boss 的同時走位防禦特感偷襲，還原最硬核的團隊抗壓體驗。
6. **100% 尊重原生地圖與尾關邏輯（Zero Softlock Guarantee）**：
   * 嚴禁關閉原生導演系統（保留 `director_allow_infected_bots 1` 與 `director_no_bosses 0`）。
   * 尾關（Finale）嚴禁隨機亂出路途 Tank，只在原生地圖腳本觸發 Boss 階段時進行順應性倍增（1 隻變 2 隻、2 隻變 3 隻），救援載具與倒數計時 100% 照原廠流程進行。

---

## 2. 雙層非同步決策迴圈與動態難度（DDA）矩陣

### 2.1 雙層解耦架構 (Macro-Intent vs. Micro-Execution)

```
┌─────────────────────────────────────────────────────────────┐
│                   外部 AI 決策微服務 (Python)               │
│  - 接收濃縮戰況標籤 (生還者人數, 彈藥, 滅團次數, MVP 識別)  │
│  - 動態調整：波次冷卻 (20~50s)、MVP 特攻組隊、Tank 數量血量 │
└─────────────────────────────────────────────────────────────┘
                               ▲  │
       Telemetry JSON (每 10~15s) │  │ DirectorDecision JSON (延遲 < 300ms)
                               │  ▼
┌─────────────────────────────────────────────────────────────┐
│                 SourceMod 執行器 (l4d2_llm_director)        │
│  - 30 Hz 逐幀執行：NavMesh 五維死角搜尋、凍結伏擊狀態機     │
│  - 本地守門員：32 槽位保護、1/3 兵種限制、MVP 特攻 <= 1/2   │
│  - 非破壞性掛鉤：順應原生終局波次與 Tank 生成倍增           │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 動態難度自適應（DDA）調控矩陣

系統絕非單純讓遊戲變難或變簡單，而是像專業地下城主（DM）一樣，將團隊心流維持在黃金抗壓區間：

| 戰況診斷 (Situation) | 觸發特徵標籤 (Telemetry Condition) | AI 戰略意圖 (Intent) | 下一波 CD | 特感兵種組合與策略 | Tank 調控策略 |
| :--- | :--- | :--- | :---: | :--- | :--- |
| **強勢碾壓期**<br>(Climax Pressure) | 全隊血量 > 75%、彈藥 > 80%、上一波特感在 4 秒內被光速清空 | `ESCALATE_CLIMAX` | **20 ～ 25 秒** | 增加 Spitter/Charger 強拆抱團，啟用 `freeze: true` 轉角同步伏擊 | 原生出 Tank 時直接觸發 `ADD_2_TANKS`（1變3），血量打折提高容錯 |
| **頂尖玩家 Carry**<br>(MVP Dominating) | 某單一玩家輸出佔比 > 40%、連續斬殺特感且無傷推進 | `ASSASSINATE_MVP` | **25 ～ 32 秒** | **發動特攻小隊（上限 $\le 1/2$ 特感）**：Spitter 封走位 + Charger/Smoker 專門鎖定 MVP，其餘特感牽制隊友 | 順應原生出 Tank，並命令小怪 `L4D2_RushVictim` 圍堵 MVP |
| **正常推進期**<br>(Standard Flow) | 全隊互有受傷（血量 40%~70%）、無人倒地、彈藥 40%~80% | `MAINTAIN_GAUNTLET_FLOW` | **30 ～ 40 秒** | 混合編制（1 控場 + 1 騷擾 + 1 輔助），針對前鋒孤狼單點施壓 | 原生出 Tank 時觸發 `ADD_1_TANK`（1變2，血量 $5000 + 800 \times N$） |
| **滅團邊緣期**<br>(Mercy Relief) | 2 人以上倒地、多人黑白、全隊彈藥 < 25%、或本關已滅團重來 $\ge 2$ 次 | `MERCY_RELAX_ALLOW_HEAL` | **45 ～ 60 秒** | **暫停強控場特感**，僅派遣散怪 Boomer/小丑，留出 15 秒以上救人打包空檔 | 攔截阻止額外 Tank，僅保留原生地圖最底線 Boss |

---

## 3. 濃縮戰況遙測規格 (Telemetry Snapshot Schema)

插件端於本地進行特徵提取（Feature Extraction），包含生還者影響力指數（MVP Impact Score）評定，JSON Payload 嚴格限制在 220 Tokens 內：

```json
{
  "match_context": {
    "map_name": "c2m5_concert",
    "chapter_progress_pct": 68.5,
    "native_stage": "FINALE_HALFTIME_BOSS",
    "is_native_infinite_horde": false,
    "map_prohibits_bosses": false,
    "wipe_count": 1,
    "active_tanks": 1
  },
  "team_metrics": {
    "survivor_count": 8,
    "alive_survivors": 7,
    "target_si_limit": 9,
    "avg_intensity": 0.58,
    "team_ammo_avg_pct": 42.0,
    "flow_spread": 620.0,
    "formation_tag": "TIGHT_GROUP",
    "incapped_or_hanging": 1,
    "black_and_white_count": 0,
    "medkits_total": 4,
    "throwables_total": 2,
    "last_assault_score": {
      "si_wiped_duration_sec": 7.2,
      "damage_dealt_to_survivors": 185,
      "incaps_caused": 1
    }
  },
  "survivor_focus": [
    {
      "slot": "P_MVP",
      "name": "Ellis",
      "hp": 92,
      "temp_hp": 0,
      "weapon": "SHOTGUN",
      "ammo_pct": 68.0,
      "dist_to_nearest_ally": 450,
      "pinned": false,
      "impact_score": 85.5,
      "impact_tags": ["TOP_DAMAGE", "SI_SLAYER"]
    },
    {
      "slot": "P_VULNERABLE",
      "name": "Rochelle",
      "hp": 24,
      "temp_hp": 15,
      "weapon": "RIFLE",
      "ammo_pct": 12.0,
      "dist_to_nearest_ally": 80,
      "pinned": false,
      "impact_score": 18.0,
      "impact_tags": ["LOW_AMMO", "CRITICAL_HP"]
    }
  ]
}
```

---

## 4. AI 決策型別與受限解碼規格 (Director Decision Spec)

### 4.1 結構定義 (`DirectorDecision` Type)

```typescript
export interface DirectorDecision {
  // 1. 局面戰略診斷
  situation:
    | "SPEEDRUNNER_ISOLATED"    // 前鋒孤狼脫隊
    | "REAR_STRAGGLER_EXPOSED"  // 殿後人員落單
    | "MVP_PLAYER_CARRYING"     // 核心頂尖玩家統治全場
    | "CORNER_CAMPING_STRONG"   // 抱團龜縮強勢防禦
    | "TEAM_CRITICAL_EXHAUSTED" // 殘血/彈盡/滅團危機
    | "HEALTHY_STEADY_PUSH"     // 穩定推進中
    | "NATIVE_INFINITE_RUSH"    // 原生衝刺無限屍潮中
    | "FINALE_BOSS_STAGE";      // 尾關 Tank 決戰中

  // 2. 本波戰術意圖
  intent:
    | "SNIPE_LONE_WOLF"         // 針對落單玩家
    | "ASSASSINATE_MVP"         // 特攻斬首最有影響力玩家
    | "BREAK_CAMPING_FORMATION" // 破壞抱團陣型
    | "MERCY_RELAX_ALLOW_HEAL"  // 放緩節奏給予自救逆轉機會
    | "ESCALATE_CLIMAX"         // 全面施壓製造高潮
    | "MAINTAIN_GAUNTLET_FLOW"; // 維持原生節奏

  // 3. 波次冷卻調控 (動態心流核心，單位：秒)
  next_wave_delay_sec: 20 | 28 | 35 | 45 | 55;

  // 4. 目標鎖定與特攻隊指派
  target: "P_MVP" | "P1_FRONT" | "P_VULNERABLE" | "NONE";
  focus_strike: boolean; // 是否啟用特攻隊針對目標 (本地守門員限制最多 1/2 活體特感)
  dir: "FRONT" | "MIDDLE_FLANK" | "BEHIND" | "ABOVE_ROOF" | "BELOW_FLOOR";

  // 5. 本波核心特感組合（本地守門員強制執行 1/3 兵種限制）
  primary_sp: "HUNTER" | "SMOKER" | "JOCKEY" | "CHARGER" | "SPITTER" | "BOOMER";
  secondary_sp: "HUNTER" | "SMOKER" | "JOCKEY" | "CHARGER" | "SPITTER" | "BOOMER" | "NONE";
  freeze_ambush: boolean; // 是否啟用轉角視線自動解凍伏擊

  // 6. 屍潮倍率
  horde: "KEEP_NATIVE" | "SCALE_0.5X" | "SCALE_1.2X" | "SCALE_1.6X" | "RIOT_SQUAD";

  // 7. Boss (Tank) 調控策略
  boss:
    | "RESPECT_NATIVE"          // 完全聽憑原生地圖劇本
    | "ADD_1_TANK"              // 原生出 1 隻變 2 隻（或尾關 2 隻變 3 隻）
    | "ADD_2_TANKS"             // 原生出 1 隻變 3 隻（強勢局限定）
    | "BLOCK_EXTRA_RESPAWN";    // 阻止額外 Tank 重生，保護殘血團隊通關
}
```

---

## 5. 多人底層引擎控制顆粒度與守門規範

### 5.1 不對稱槽位動態計算與 32 槽位安全紅線
1. **動態槽位公式**：
   $$\text{target\_si\_limit} = \text{alive\_survivors} + 2$$
2. **32 槽位防爆守門員（MaxClients Guard）**：
   * Source 引擎全伺服器最大實體客戶端槽位為 32。
   * 插件在執行任何特感或 Tank 生成前，必須進行安全校驗：
     ```pawn
     int totalClients = GetClientCount(false);
     if (totalClients + neededSpawns > 28) {
         // 保留至少 4 個安全槽位，暫緩生成，避免伺服器溢位崩潰
         return;
     }
     ```

### 5.2 兵種防自閉限制（Anti-Hard-CC Cap）
為防止 8～10 人局隨機刷出 5 隻 Charger 或 5 隻 Hunter 導致生還者瞬間全滅，插件於本地建立**硬性配額檢查**：
```pawn
int maxPerClass = RoundToCeil(float(aliveSurvivors) / 3.0);
// 例如：6 人局每種最多 2 隻；9 人局每種最多 3 隻
if (GetSpecialCount(requestedClass) >= maxPerClass) {
    // 強制轉移至非控場特感 (Spitter 或 Boomer)
    requestedClass = (GetRandomInt(0, 1) == 0) ? ZOMBIECLASS_SPITTER : ZOMBIECLASS_BOOMER;
}
```

### 5.3 MVP 影響力評估與特感集火特攻隊（Focus Strike Team）實作規格
為針對遊戲中最強的 Carry 玩家施壓，同時避免全場特感無腦集火導致玩家體驗崩潰，實作必須遵循以下規範：

1. **生還者影響力指數（Impact Score）計算公式**：
   $$\text{Score}_i = (\text{SI Kills} \times 3) + (\text{Teammate Revives} \times 5) + (\text{Pins Cleared} \times 4) + \left(\frac{\text{Damage Dealt}}{100}\right)$$
   每 10 秒計算最高分者標記為 `P_MVP`。
2. **「最多 1/2 特感」組隊硬性限制（Focus Squad Size Cap）**：
   $$\text{Max Focus Attackers} = \left\lfloor \frac{\text{Active SI Count}}{2} \right\rfloor$$
   * 例如場上活著 10 隻特感，特攻小隊**最多指派 5 隻**鎖定 `P_MVP`。
   * **其餘 5 隻特感必須強制分流攻擊其他生還者**，牽制隊伍防線，迫使隊友進行極限救援。
3. **Left 4 DHooks Direct 底層單點鎖定鏈路**：
   * **仇恨覆寫**：掛鉤 `forward Action L4D2_OnChooseVictim(int specialInfected, int &curTarget)`。
     若該 `specialInfected` 屬於特攻小隊成員，直接將 `curTarget = mvpClient; return Plugin_Changed;`，覆寫原生 AI 索敵。
   * **指令下達**：生成瞬間呼叫 `L4D2_CommandABot(bot, mvpClient, BOT_CMD_ATTACK)`。
   * **強制控場優先順序（Guaranteed Pin）**：
     * Hunter 接近時呼叫 `L4D_ForceHunterVictim(mvpClient, hunterBot)`。
     * Smoker 於視線內呼叫 `L4D_ForceSmokerVictim(mvpClient, smokerBot)`。
     * Jockey 於跳躍判定時呼叫 `L4D2_ForceJockeyVictim(mvpClient, jockeyBot)`。
   * **小怪協同**：特攻啟動時，同步呼叫 `L4D2_RushVictim(mvpClient, 2000.0)`，逼迫 MVP 面對小怪與特感夾擊。

### 5.4 多 Tank 平行協同與分幀防卡頓（Stagger Spawns）
1. **血量動態公式**：
   $$\text{Tank HP} = 5000 + (n \times \text{alive\_survivors})$$
   （預設 $n = 800$，例如 8 人局單隻 Tank 血量為 $5000 + 6400 = 11400$）。
2. **分幀生成佇列**：
   若 AI 指令為 `ADD_1_TANK` 或 `ADD_2_TANKS`，嚴禁在同一 Tick（33ms）內連續呼叫 `L4D2_SpawnTank`，必須以 **0.1 秒間隔排程** 生成，並在位置上加入 $\pm 120.0$ 單位的座標微移，防止多隻 Tank 模型重疊穿模。
3. **Tank 期間特感不中斷**：
   嚴格移除傳統插件的 `m_bTankDisableSpawn` 鎖，Tank 衝鋒吸引火力時，特感波次依舊照常由死角發動突襲。

---

## 6. 「100% 尊重原生地圖與尾關邏輯」非破壞性規範 (Zero-Break Specification)

### 6.1 為什麼傳統插件容易壞圖，而本架構保證不壞？
Valve 在底層（`server.dll`）將導演系統拆解為四個**互不相干的獨立模組**：
1. **終局與關卡實體模組 (`trigger_finale`, `info_director`, VScript)**：負責監聽按鈕、計算計時、派遣救援直升機。
2. **Boss 生成模組 (`CDirectorBossPlayer`)**：負責計算 0%~100% 路程點，派遣 Tank 與 Witch。
3. **小特感步調模組 (`CDirectorPZPlayer`)**：負責日常 6 種小特感。
4. **屍潮突襲模組 (`CDirectorMobSpawner`)**：負責警報車、開關推土機與警報屍潮。

> [!CAUTION]
> **傳統插件（如 `l4d2_zombie_master`）之所以會壞圖**，是因為它把 `director_no_bosses` 設為 1，並把 VScript 的 `coop.nut` EMS HUD 獨佔覆寫，導致終局狀態機無法獲取 Tank 死亡通知，造成**救援載具永遠不來的軟鎖死（Softlock）**！

### 6.2 尾關（Finale）安全介入守則
本 AI 導演系統**完全不介入終局計時與波次推進**，僅採用以下兩條非破壞性微調原則：

```
                      【尾關安全掛鉤運作圖】
                      
 [原生 trigger_finale] 
         │ 
         ▼ (推進階段：FINALE_HALFTIME_BOSS)
 [原生生出第 1 隻 Tank] ────► 觸發 L4D_OnSpawnTank_Post
                                      │
                                      ▼
                        【AI 導演判斷團隊狀態】
                         若團隊健康且預算充足：
                         - 延遲 1.5 秒補生第 2 隻 Tank
                         - 依公式設定兩隻 Tank 血量
                         - 救援計時器完全不受影響正常倒數！
```

1. **嚴禁在尾關隨機生成路途 Tank**：
   AI 決策微服務在 `native_stage` 處於非 Boss 階段（如 `FINALE_HORDE_ATTACK`）時，強制鎖定 `boss: "RESPECT_NATIVE"`，絕不在玩家守點時無端生出額外 Tank。
2. **順應原生時機倍增（Additive Only）**：
   掛鉤 `L4D_OnSpawnTank_Post`：當原生地圖自己的劇本生出 Tank 時，AI 僅在此時「跟隨加碼」。
   * 第一波原生出 1 隻 ➔ 順應加碼為 2 隻。
   * 第二波原生出 2 隻 ➔ 順應加碼為 3 隻。
   * **地圖腳本依舊能正確捕獲所有 Tank 的死亡事件，救援載具 100% 準時到達！**

---

## 7. 交付檢查清單與實作里程碑 (Milestones)

1. **Milestone 1 — 多人遙測與波次通訊原型（Day 1–2）**：
   * 移除 `l4dinfectedbots.smx` 至 `disabled/`。
   * 實作 `l4d2_llm_director.sp`，使用 `REST in Pawn` 向外部 Python 傳遞包含 `survivor_count (4~10)`、`team_ammo_avg_pct`、`wipe_count`、`P_MVP` 評分的遙測 JSON。
2. **Milestone 2 — 外部 AI 決策與 DDA 矩陣（Day 3–4）**：
   * 部署 FastAPI 微服務，實作第 2.2 節的 DDA 難度矩陣與 `ASSASSINATE_MVP` 意圖。
   * 驗證 AI 能在 Carry 玩家獨大時精準下達斬首指令，在瀕死卡關時放寬冷卻至 50 秒。
3. **Milestone 3 — 多人槽位、兵種守門員與特攻小隊實裝（Day 5–6）**：
   * 實作 $N+2$ 特感動態槽位計算與 28 槽位安全紅線保護。
   * 實作 $\le 1/3$ 控場特感上限攔截器與多 Tank 分幀生成佇列。
   * 實作 `L4D2_OnChooseVictim` + `L4D2_CommandABot` + `L4D_Force*Victim` 特攻組隊邏輯，嚴格落實 $\le 1/2$ 特感集火限制。
4. **Milestone 4 — 官方戰役與自訂地圖尾關全流程壓測（Day 7）**：
   * 於《黑色狂歡節 (c2m5_concert)》與《教區 (c5m5_bridge)》進行 8 人聯機實測。
   * 驗證教區跑橋無限屍潮不被中斷、音樂公園尾關三 Tank 混戰下救援直升機 100% 正常抵達。
