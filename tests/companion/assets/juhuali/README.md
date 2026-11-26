# Juhuali / 菊花梨 — optional test asset

- Author and copyright: Moemark, 2026.
- Source: https://github.com/Moemark/codex-pet-juhuali
- Fixed revision: 73d50ad6ab61a95d92660b868529ebece9a84a4b
- Source file: spritesheet.webp (2,218,452 bytes)
- SHA-256: 7f21d59534ca4500b6fa64361c5518a6533dcdfffebc79aac05dcbd77d75d847
- License: MIT; upstream README explicitly includes the pet spritesheet.
- Format: classic V2, 1536 x 2288, 8 x 11 cells of 192 x 208.
- Use: optional manual desktop rendering test only; not Pulse branding or an official OpenAI asset.

The unmodified atlas is fetched explicitly with
`python scripts/fetch_pet_test_asset.py`, into ignored zig-out/test-assets/juhuali/.
No upstream install script is run. No changes are made to Codex or OpenPets.
The full upstream license is retained in LICENSE. Default CI and demo remain
self-contained using original geometric pixels. Actual rendering depends on
the local WIC codec and the strict atlas subset; verify on Windows.

From the repository root after building pulse-pet-demo.exe:

```powershell
python scripts/fetch_pet_test_asset.py
.\pulse-pet-demo.exe --webp-v2 "$PWD\zig-out\test-assets\juhuali\spritesheet.webp"
```
