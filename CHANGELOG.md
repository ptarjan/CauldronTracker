# Changelog

## 1.0.11
- Update Interface to 120105 for patch 12.1.5

## 1.0.10
- Fix: the addon errored out on every cauldron cast and every loot message under WoW 12.x — the check for "secret" values ran after a test that itself threw on a secret. Flask counting works again.
- Fix: replaced WoW API calls that were deprecated in 12.x

## 1.0.9
- Ready for WoW 12.1.0

## 1.0.8
- Fix: raids that run past midnight no longer split their counts across two days — flasks taken after 12am count toward the night the cauldron was placed
- Fix: a cauldron's 5-minute window now survives a /reload, so flasks taken right after reloading are still counted
- Fix: flasks crafted long before a cauldron was placed could wrongly count toward it
- Fix: `/cauldron all` printed a garbage section that wasn't a real day
- Fix: the tracker window no longer slowly uses more memory the longer it stays open during a raid
- Update for WoW 12.0.7

## 1.0.7
- Stop counting personal alchemy crafting at a workbench as cauldron use — stacks of 5 (or any quantity > 1) are now ignored, since flask cauldrons only hand out one item per charge
- Also count single-craft potions taken from the flask cauldron (previously only items with "flask" or "phial" in the name were counted, missing cauldron potions)
- More reliable cauldron detection: matches the exact placement spell (Algari and Midnight Flask Cauldron) instead of guessing from the spell name
- Only count cauldron uses within its 5-minute active window after placement
- Burst detection now requires 3 different people creating within 30 seconds (was: any 3 creates), so one person spam-crafting at a bench can't fake a cauldron

## 1.0.6
- Fix the addon counting one cauldron as two when people kept clicking it for more than a minute — the "X each" number was getting doubled
- Fix individual flask counts sometimes being one too high — duplicate loot messages from WoW (the same flask appearing as both "You receive" and as a group broadcast) are now ignored
- Show how many cauldrons were placed in the UI title (e.g. "2 each (1 cauldron)") so you can see what got counted
- Fix `/cauldron all` and `/cauldron <date>` crashing
- Fix `/cauldron add Bob` storing the name in lowercase
- Always log every flask loot to saved variables (last 500 entries) so the addon can be debugged after the fact. `/cauldron clearlog` to wipe it.

## 1.0.5
- Update for WoW 12.0.5
- Burst detection: if 3+ flask loots happen within 30 seconds, count it as a cauldron even if the placement spell wasn't detected

## 1.0.4
- Fix false cauldron detection when taking from cauldron (now only detects placement)
- Add /cauldron add [player] command to manually record cauldron placement

## 1.0.3
- Fix taint error from registering COMBAT_LOG_EVENT_UNFILTERED in WoW 12.0

## 1.0.2
- Fix errors from WoW 12.0 changes to loot messages
- UI updates in real-time when flasks are looted or cauldrons placed

## 1.0.1
- Fix title wrapping on UI

## 1.0.0
- Initial release
- Track flask/phial loots per player per day
- Detect cauldron placement and calculate allotment (40 charges / raid size)
- Banner-style UI with player/count columns
