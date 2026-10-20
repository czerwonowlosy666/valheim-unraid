# Valheim server for Unraid (Thunderstore mods, auto-updates, custom seed)

A Docker app for Unraid that runs a Valheim dedicated server and:

- **Installs mods from Thunderstore**: list mods by name or link, or paste an r2modman / Thunderstore Mod Manager **profile code**. BepInEx and all dependencies are installed for you.
- **Updates automatically**: checks Valheim and every mod in the background, waits until nobody is online, backs up the world, then restarts with the new versions.
- **Lets you pick the world seed** (plus difficulty preset and world modifiers) for new worlds.
- Saves the world cleanly when the container stops, restarts the server if it crashes, and keeps rolling world backups.

---

## 1. Publish the image (one time)

1. Create a GitHub repository called `valheim-unraid` and push this folder to it.
2. Replace `czerwonowlosy666` in `unraid/valheim-thunderstore.xml` with your GitHub username (lowercase) and push.
3. The **Build image** action runs the tests and publishes `ghcr.io/<you>/valheim-unraid:latest`.
4. On GitHub go to your profile, **Packages**, **valheim-unraid**, **Package settings**, and set visibility to **Public** so Unraid can pull it without logging in.

The image does not contain the game. Valheim is downloaded by SteamCMD on first start and updated from then on, so you only need to rebuild the image when you change the scripts. The workflow also rebuilds weekly to pick up Debian security fixes.

## 2. Add it to Unraid

Open the Unraid terminal and run:

```bash
wget -O /boot/config/plugins/dockerMan/templates-user/my-valheim-thunderstore.xml \
  https://raw.githubusercontent.com/czerwonowlosy666/valheim-unraid/main/unraid/valheim-thunderstore.xml
```

Then go to **Docker**, **Add Container**, choose **valheim-thunderstore** from the Template list, fill in the settings and click **Apply**.

The first start downloads about 1 GB, so watch the container log until you see `Game server connected`. To play over the internet, forward **UDP 2456-2457** on your router to your Unraid server.

## Settings

The main settings are shown by default; click **Show more settings** in the template for the rest.

| Setting | Variable | Default | Notes |
|---|---|---|---|
| Server name | `SERVER_NAME` | My Valheim Server | |
| World name | `WORLD_NAME` | Dedicated | Changing it starts a new world. Old worlds stay in `saves/`. |
| Password | `SERVER_PASS` | | At least 5 characters, not part of the server name. |
| World seed | `WORLD_SEED` | random | Only used when the world is created. See below. |
| Public | `SERVER_PUBLIC` | false | Show in the community server list. |
| Crossplay | `CROSSPLAY` | false | Lets Xbox / Game Pass players join. |
| Admins | `ADMINS` | | SteamID64s, comma separated. Written to `saves/adminlist.txt`. |
| Mods | `MODS` | | See below. |
| Profile code | `THUNDERSTORE_PROFILE_CODE` | | See below. |
| Exclude mods | `MODS_EXCLUDE` | | Mods to skip, e.g. client-only UI mods from your profile. |
| Auto update | `AUTO_UPDATE` | true | Background checks. Updates are always applied when the container starts. |
| Update check interval | `UPDATE_CHECK_INTERVAL` | 60 | Minutes. |
| Only update when empty | `UPDATE_WHEN_IDLE` | true | Waits for 0 players before restarting. |
| Max wait for empty server | `UPDATE_MAX_WAIT` | 360 | Minutes, then it restarts anyway. 0 = never force. |
| Update Valheim / Update mods | `SERVER_AUTO_UPDATE` / `MODS_AUTO_UPDATE` | true | Turn either part of auto-update off. |
| Steam branch | `STEAM_BRANCH` | public | e.g. `public-test` (with `STEAM_BRANCH_PASSWORD`). |
| Difficulty preset | `WORLD_PRESET` | | normal, casual, easy, hard, hardcore, immersive, hammer |
| World modifiers | `WORLD_MODIFIERS` | | e.g. `combat:hard, raids:none, resources:more` |
| World keys | `WORLD_KEYS` | | e.g. `nomap, playerevents` |
| Backup on restart / Backups to keep | `BACKUP_ON_RESTART` / `BACKUP_KEEP` | true / 10 | |
| Extra server arguments | `SERVER_ARGS` | | Passed straight to `valheim_server`, e.g. `-saveinterval 600`. |
| PUID / PGID | `PUID` / `PGID` | 99 / 100 | Unraid's nobody:users. |

## Mods

**By name.** Put mods in **Mods**, separated by commas. Each one can be:

- `Author-ModName`: always the latest version, auto-updated.
- `Author-ModName-1.2.3`: pinned to that version, never updated.
- A Thunderstore link such as `https://thunderstore.io/c/valheim/p/Azumatt/AzuCraftyBoxes/`.

Example: `ValheimModding-Jotunn, Azumatt-AzuCraftyBoxes, Smoothbrain-ServerCharacters-1.4.0`

You don't need to list BepInEx or dependencies. Modpacks work too: add the modpack and everything it depends on gets installed.

**From your mod manager.** In r2modman or Thunderstore Mod Manager open **Settings**, **Profile**, **Export profile as code**, and paste the code into **Profile code**.

- Disabled mods in the profile are skipped.
- Mods are updated to their latest versions unless you set **Pin profile versions** to true.
- The profile's config files are copied the first time, but files you already have are never overwritten.
- Codes expire after a while. The container keeps its own copy of the profile, so it keeps working.
- Many profiles include client-only mods (UI, minimap and so on). Put those in **Exclude mods**.

**Your own plugins.** DLLs that aren't on Thunderstore can go in `custom-plugins/` inside the Data folder. They are copied into BepInEx on every start, and BepInEx is installed automatically if needed.

**Mod configs** live in `bepinex-config/` inside the Data folder. Edit them there and restart the container.

**Removing a mod.** Remove it from the list and restart. Its files are deleted, but its config file is kept.

Players need the same gameplay mods on their PC. The easiest way is to share the same r2modman profile code with them.

## World seed

Valheim's server has no seed option, so the container writes the new world's metadata file itself, using the 1.0 world format, before the first start. The server then generates the world from that seed.

- The seed is 1-10 characters, exactly as you would type it in the game.
- It only applies to a world that doesn't exist yet. If `WORLD_NAME` already exists, the log warns you and the existing world is left alone. To use a new seed, choose a new world name.
- The seed of the running world is shown in the log at every start (`World: Dedicated (seed: ...)`).

You can also use an existing world. Stop the container, copy the world into `saves/worlds_local/` (the whole world folder for Valheim 1.0 worlds, or the `Name.db` + `Name.fwl` pair for older ones), and set **World name** to match. Keep a copy of the original until you've checked it loads.

## Updates

Every time the container starts it updates Valheim through SteamCMD and syncs mods with Thunderstore. While it runs, the updater checks every `UPDATE_CHECK_INTERVAL` minutes:

1. It compares the installed Valheim build with Steam, and every mod with Thunderstore.
2. If something is new, it waits for 0 players. It reads the player count from the Steam query port. With crossplay the count isn't available, so it waits `UPDATE_MAX_WAIT` minutes instead.
3. It stops the server, which saves the world. Then it backs up the world, installs the updates and starts the server again.

If Thunderstore is down, the server starts with the mods it already has. Nothing is removed just because a lookup failed.

## Folders

Data (`/config`, default `/mnt/user/appdata/valheim/data`):

```
saves/worlds_local/   your worlds
saves/adminlist.txt   admins / bannedlist.txt / permittedlist.txt
backups/              world backups (.tar.gz), newest BACKUP_KEEP kept
bepinex-config/       mod config files
custom-plugins/       your own plugin DLLs
logs/valheim.log      server log (previous runs: valheim.log.1 ... .4)
```

Server files (`/opt/valheim`, default `/mnt/user/appdata/valheim/server`) holds the game, BepInEx and installed mods. You can delete it at any time; it is re-downloaded.

**Restore a backup.** Stop the container, delete `saves/worlds_local/<World>`, and extract the backup inside `saves/` with `tar -xzf ../backups/<file>.tar.gz`. Then start the container.

## Troubleshooting

- **Players can't find the server.** Join with the IP instead: in Valheim choose **Join IP** and enter `your-public-ip:2456`. Check that UDP 2456-2457 is forwarded. The community list can take a few minutes to show a new server.
- **The server stops right after starting.** Check the password rules above, and look at `logs/valheim.log`.
- **A mod breaks the server.** Pin it to an older version (`Author-Mod-1.2.3`) or add it to **Exclude mods**, then restart.
- **The container takes a long time to stop.** It is saving the world. The template gives it 120 seconds (`--stop-timeout=120`) so Unraid doesn't kill it mid-save.

## Development

```
scripts/supervisor.sh     main loop: update, mods, world, start; restart and stop handling
scripts/updater.sh        background update checker
scripts/thunderstore.py   Thunderstore mod manager (sync / check / list)
scripts/valheim_world.py  world metadata writer for custom seeds
scripts/player_count.py   Steam A2S player count
tests/                    offline tests with a mock Thunderstore, fake SteamCMD and fake server
```

Run the tests with `bash tests/test_mods.sh && bash tests/test_supervisor.sh`. They need Python 3 with PyYAML, and no network or Docker.

The seed format is ported from [MakeFwl](https://github.com/CrystalFerrai/MakeFwl) by Crystal Ferrai (Apache-2.0).
