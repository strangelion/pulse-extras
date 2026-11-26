# Hoodie Cat — optional wardrobe test asset

Source: https://github.com/OpenPetsHQ/openpets/tree/2f02bb04d872dec6923a47572343305235c63482/apps/desktop/assets
Fixed revision: 2f02bb04d872dec6923a47572343305235c63482
Copyright (c) 2026 OpenPets. Upstream repository MIT license:
https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/LICENSE

The locally authored pet.json maps the upstream built-in V2 wardrobe into
the Classic package contract. Schedule order follows packages/pet-format/src/builtin-hoodie-cat.ts.
The script checks each original atlas's pinned Git blob object ID and byte
size, and fetches the original MIT license adjacent to the package. Git
SHA-1 object IDs are not SHA-256 security digests. Artwork not vendored.
The original Juhuali default command remains unchanged.

From the repository root:

```powershell
python scripts/fetch_pet_test_asset.py --pet hoodie-cat
zig build pet-demo -Doptimize=ReleaseSafe -Dpet-libwebp=true
.\zig-out\bin\pulse-pet-demo.exe --check-package "$PWD\zig-out\test-assets\hoodie-cat" hoodie-cat
.\zig-out\bin\pulse-pet-demo.exe --package "$PWD\zig-out\test-assets\hoodie-cat" hoodie-cat
```

Right-click the pet, select a fixed outfit, then select Automatic (schedule).
Check all five outfits, default, persistence after exit/relaunch, and that
the current artwork stays visible during a switch. Actual network download
and rendered outfit transitions require Windows user verification.
