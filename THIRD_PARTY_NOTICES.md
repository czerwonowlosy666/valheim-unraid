# Third-party notices

## MakeFwl

`scripts/valheim_world.py` contains a Python port of the Valheim world
metadata format and seed hashing from MakeFwl.

- Project: https://github.com/CrystalFerrai/MakeFwl
- Copyright 2026 Crystal Ferrai
- License: Apache License 2.0, https://www.apache.org/licenses/LICENSE-2.0

Licensed under the Apache License, Version 2.0 (the "License"); you may not use
this file except in compliance with the License. Unless required by applicable
law or agreed to in writing, software distributed under the License is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
either express or implied. See the License for the specific language governing
permissions and limitations under the License.

Changes: rewritten in Python; world modifiers are passed as server launch
arguments instead of being written into the metadata file.

## Not included in this project

This project contains no game files. At runtime the container downloads:

- **Valheim Dedicated Server** (Steam app 896660) by Iron Gate AB, through
  SteamCMD, under Valve's and Iron Gate's terms.
- **SteamCMD** by Valve Corporation, under the Steam Subscriber Agreement.
- **BepInExPack_Valheim** and any mods you choose, from Thunderstore, each
  under its own author's license.

Valheim is a trademark of Iron Gate AB. This project is not affiliated with or
endorsed by Iron Gate, Coffee Stain, Valve or Thunderstore.
