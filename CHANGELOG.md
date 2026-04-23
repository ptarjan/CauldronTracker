# Changelog

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
