# Editor sheet: chrome and tab content bottom-aligned for one-handed reach

The exercise editor sheet is the practitioner's most-frequent editing surface and must work one-handed (practitioners often hold a clipboard or phone the client while editing). The chrome (drag pill stub, tab strip, bottom rail with Hero thumbnail + chevrons + editable title) was inverted to the bottom of the sheet on 2026-05-06; tab content now follows the same principle. Plan / Notes / Settings tab bodies lay out from the bottom of the PageView area upward — most-tappable controls pin just above the tab strip and empty space fills the top. The Demo tab is unaffected (full canvas for the video). The per-tab detent rule (Demo=0.95, others=0.75) is dropped; the sheet always opens and stays at 0.95. The 0.75 floor remains reachable via manual drag-down for a Studio peek.

## Considered Options

We considered keeping the per-tab rule (causes 0.95↔0.75 oscillation during cross-tab continuous swipe under Mode A + wrap; `animateTo` smoothing was already tried and abandoned because PageView pan deltas feed the same `DraggableScrollableSheet` and cancel in-flight animations mid-flight — see [exercise_editor_sheet.dart:308](../../app/lib/widgets/exercise_editor_sheet.dart:308)) and dropping the rule without bottom-aligning content (undoes the reachability work the chrome inversion shipped). Both rejected.
