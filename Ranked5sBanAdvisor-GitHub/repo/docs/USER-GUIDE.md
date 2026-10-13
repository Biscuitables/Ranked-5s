# Ranked 5s Ban Advisor

**Version 1.6.3** · Windows 10 / 11 · Free

Ranked 5s Ban Advisor is a small helper for League of Legends champ select. When champ select starts, it finds the enemy team, looks at their recent games and shows:

- **Suggested bans**, ranked by how much each enemy relies on a champion. Recent games count more, and games they played with their current teammates count extra.
- **An enemy team card for each player**, with their rank, role, win rate, KDA, CS per minute, most-played champions, strengths, weaknesses and who they usually queue with.
- **After a player locks in**, how they play that champion. For junglers it also shows their early jungle pathing: which side they start on, which lane they visit first, and whether they invade.
- **At the loading screen**, Porofessor's player tags, such as "Invader," "OTP Fizz" or "Tilted."
- **After the game**, your win/loss record for the session. A small "Victory" animation plays when you win.

Everything runs on your own PC. The dashboard opens in your web browser at `http://localhost:8765`.

---

## Install

1. Download **Ranked5sBanAdvisor.zip**.
2. Right-click the zip → **Extract All…** → **Extract**.
3. Open the new **Ranked5sBanAdvisor** folder. **Ranked5sBanAdvisor.exe** is the whole app; there's nothing else to install.

## First run

1. Open League of Legends and sign in.
2. Double-click **Ranked5sBanAdvisor.exe**.
3. The first time, Windows may show a blue **"Windows protected your PC"** box. Click **More info** → **Run anyway**. This appears for any app that isn't signed with a paid code-signing certificate.
4. Your browser opens the dashboard, and a small gold hexagon icon appears near the clock.
5. Queue up as usual. The dashboard fills in by itself when champ select starts.

**The icon near the clock:** double-click it to reopen the dashboard. Right-click it for **Show log** or **Quit Ranked 5s Ban Advisor**. If you open Ranked5sBanAdvisor.exe while it's already running, it just reopens the dashboard.

---

## Choosing how it finds the enemy team

Use the tabs under the title bar. Your choice is remembered.

| Tab | What it does | When to use it |
|---|---|---|
| **Auto** (default) | Uses the League client when it can, and reads the screen only when it can't. | Most of the time. |
| **League client** | Reads champ select straight from your League client. | This is the most accurate, because it gets exact names with #tags. |
| **Screen reading** | Reads the enemy names off the League window, then looks them up on op.gg. | If the client method isn't working. Keep champ select visible; the window can be behind others but not minimized. |

**Region** sets which server op.gg and Porofessor look players up on. When the League client is connected, it's filled in automatically.

When screen reading finds several accounts with the same name, it picks the one that played most recently. The card then says **"Best match of N accounts."** Use the op.gg link on the card to double-check.

---

## Riot API key (optional)

Ranked 5s Ban Advisor works without a key. With your own Riot API key, it gets match history, ranks, mastery and jungle timelines straight from Riot instead of op.gg, which is faster and more reliable.

1. Go to **developer.riotgames.com** and sign in with your Riot account.
2. On the dashboard, copy your **Development API Key** (it starts with `RGAPI-`).
3. In Ranked 5s Ban Advisor, click **Riot API** at the right of the menu bar, paste the key and click **Save key**.
4. The dot next to "Riot API" turns teal and says which server it's using (for example NA1).

Things to know:

- **Development keys expire every 24 hours.** When yours expires, the dot turns gold and the page asks for a new one. Paste the new key the same way.
- **The key stays on your PC.** It's saved in `settings.json`, encrypted for your Windows account. It's never put in a link or sent anywhere except Riot.
- **Never share your key** or put it in the app before giving the app to someone else. Each person should use their own key.
- To stop using it, open the **Riot API** panel and click **Remove**.
- Development keys are rate limited (100 calls per 2 minutes), so Ranked 5s Ban Advisor reads each player's last 12 games from Riot and paces its calls. If Riot says to slow down, it waits and continues by itself.
- If you share Ranked 5s Ban Advisor widely, apply for a **Personal** or **Production** key for the app on the developer portal. These don't expire daily.

---

## Chinese, Japanese and Korean names

Names in Chinese, Japanese and Korean work in every part of the app: the League client method, op.gg, Porofessor and the dashboard.

**Screen reading** uses Windows' built-in text recognition, which can only read the languages installed in Windows. To read Chinese, Japanese or Korean names off the screen, add those languages once:

1. Open **Settings** → **Time & language** → **Language & region**.
2. Click **Add a language**.
3. Pick the language you need: **Chinese (Simplified, China)**, **Chinese (Traditional, Taiwan)**, **Japanese** or **Korean**. Click **Next**.
4. Make sure **Optical character recognition** is ticked in the list of features. You don't need to tick "Set as my Windows display language."
5. Click **Install** and wait for it to finish.
6. Quit Ranked 5s Ban Advisor from the icon near the clock and open it again.

In Screen reading mode, the waiting screen lists the installed reading languages under "Text recognition," for example `en-US, ja, ko`. Add any languages you see in your games; adding all three is fine.

<details>
<summary>Alternative: install with one command (needs an administrator PowerShell window)</summary>

1. Press **Start**, type **PowerShell**, right-click **Windows PowerShell** → **Run as administrator**.
2. Paste the line for each language you want, and press **Enter**:

```powershell
Add-WindowsCapability -Online -Name "Language.OCR~~~zh-CN~0.0.1.0"   # Chinese (Simplified)
Add-WindowsCapability -Online -Name "Language.OCR~~~zh-TW~0.0.1.0"   # Chinese (Traditional)
Add-WindowsCapability -Online -Name "Language.OCR~~~ja-JP~0.0.1.0"   # Japanese
Add-WindowsCapability -Online -Name "Language.OCR~~~ko-KR~0.0.1.0"   # Korean
```

3. Restart Ranked 5s Ban Advisor.
</details>

Screen reading expects the League client in **English**. If your client is set to another language, use the **League client** tab instead.

---

## Where data comes from

| Source | Used for |
|---|---|
| **Your League client** (local connection on your PC) | Champ select, ranks, mastery, match history, match timelines, end-of-game result |
| **Riot Games API** (optional, your own key) | Accounts, ranks, mastery, match history and jungle timelines |
| **op.gg** | Backup for match history and timelines, and lookups for names read from the screen |
| **Porofessor** | Player tags and premade groups, once the game is on the loading screen |
| **Riot's public champion list** | Champion names when the League client isn't connected |

Ranked 5s Ban Advisor doesn't read or change the game itself, and it doesn't send your data anywhere. If the game hides a player's name, that player is skipped.

---

## Files

| What | Where |
|---|---|
| The app | Wherever you put **Ranked5sBanAdvisor.exe** |
| Settings, log and working files | `%LOCALAPPDATA%\BanAdvisor` |
| Last champ select data, for troubleshooting | `%LOCALAPPDATA%\BanAdvisor\last-session.json` |
| Backup of the current match | `%LOCALAPPDATA%\BanAdvisor\backup.json` |
| What screen reading saw | `%LOCALAPPDATA%\BanAdvisor\screen-debug\` |

**Uninstall:** quit from the icon near the clock, delete **Ranked5sBanAdvisor.exe**, then delete the `%LOCALAPPDATA%\BanAdvisor` folder.

---

## Troubleshooting

| Problem | Try this |
|---|---|
| Dashboard says **League client not found** | Open League and sign in. If it still says so, switch to **Screen reading**. |
| A card says **Couldn't find '…' on op.gg** | Check the **Region** setting. In screen mode, open "What the screen reader saw" at the bottom of the page to see if the name was read correctly. |
| Chinese, Japanese or Korean names show as boxes or are skipped in screen mode | Add the language in Windows (see above), then restart Ranked 5s Ban Advisor. |
| **Porofessor** tags never appear | They only appear once the game reaches the loading screen. Porofessor also needs the region set correctly. |
| No jungle pathing | The player has no recent jungle games, or those games had no timeline data. The card says which. |
| Something else | Right-click the icon near the clock → **Show log**, and send the last few lines along with `last-session.json`. |

---

## Version history

**1.6.3**
- The box at the bottom of the dashboard now shows your session record and the Victory celebration.

**1.6.1**
- Renamed to **Ranked 5s Ban Advisor** (the app, the window, the icon near the clock and the dashboard). Your settings and Riot API key carry over.

**1.6.0**
- Optional Riot Games API support. Paste your own key in the new **Riot API** panel to get match history, ranks, mastery and jungle timelines straight from Riot. The key is stored encrypted on your PC, checked when saved, and the app tells you when a development key expires.
- Riot calls are paced to stay within the key's rate limits; if Riot asks it to slow down, Ranked 5s Ban Advisor waits and retries.
- Fixed: Test lookups with several names now work.

**1.5.1**
- Champion pictures no longer flicker or show as black circles while the page updates.

**1.5.0**
- Backup of the last good results from champ select through the loading screen and game. If a glitch makes a card lose its data, a player drop out, or the bans vanish, the last good version is shown (marked **Last known**) until fresh data is good again.
- The backup is also saved to `backup.json`, so if Ranked 5s Ban Advisor is closed or crashes mid-match, reopening it brings the last match back (for up to 45 minutes).
- The backup clears itself when the game ends, when you go back to the lobby (dodge), or when champ select starts with different players.

**1.4.2**
- Fixed: in Screen reading mode, enemy cards could reset a few seconds after loading (names lost their #tag and showed "No recent Summoner's Rift games found"). One misread screen frame no longer makes the app forget the team, and a player's looked-up account is remembered even if the screen reader re-reads them.

**1.4.1**
- Calmer loading effect: a thin silver line runs along the top of the card instead of a shimmer across the whole card.
- A small gold lens flare glides across a player's name when their data finishes loading and again when they lock in a champion. It replaces the gold sweep across the card.

**1.4.0**
- Chinese, Japanese and Korean player names now work. League client data is read as UTF-8, and name matching and op.gg/Porofessor links handle these characters.
- Screen reading also uses any Chinese, Japanese or Korean text recognition installed in Windows.
- The dashboard footer shows the app version, and the screen-reading notes list the installed reading languages.
- Added this README.

**1.3.0**
- Porofessor tags and premade groups at the loading screen.
- "On [champion]" notes after each player locks in.
- Jungle pathing from recent match timelines.
- Silver shimmer while a player loads, and a gold sweep when their data arrives.
- Support box with a session win/loss record, and a Victory animation when you win.

**1.2.0**
- Redesigned to match the League client's look, with calmer wording throughout.
- Runs quietly with an icon near the clock instead of a black window. New icon.
- Opening the app again just reopens the dashboard.

**1.1.0**
- Added Screen reading as a second way to find the enemy team, with op.gg lookups.
- Menu to choose Auto, League client or Screen reading, plus a region picker.
- op.gg is used as a backup when the client has no match history.

**1.0.0**
- First version: reads champ select from the League client, suggests bans, shows enemy cards with strengths and weaknesses, and links to op.gg and Porofessor.
