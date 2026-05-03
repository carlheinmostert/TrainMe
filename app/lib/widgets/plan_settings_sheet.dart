import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../models/session.dart';
import '../theme.dart';

/// Default fallback for the per-plan rest-between-exercises stepper when
/// the session has no preferred value persisted yet. Mirrors the in-app
/// fallback in [Session.effectiveRestIntervalSeconds] so the stepper
/// shows the value the rest of the app will actually use.
const int _kDefaultRestSeconds = 30;

/// Default for the auto-insert rest threshold. Phase A — in-memory only.
/// TODO(phase-b): persist `autoRestThresholdSeconds` once the schema
/// migration lands. The 10-minute default mirrors
/// [AppConfig.restInsertIntervalMinutes].
const int _kDefaultAutoRestMinutes = 10;

/// One of three default-treatment options for new exercises.
/// TODO(phase-b): persist a default-treatment column on plans.
enum _DefaultTreatment { drawn, bw, colour }

/// Phase-A in-memory state for the not-yet-persisted fields in this
/// sheet. Lives on the StatefulWidget; reset to defaults every time the
/// sheet opens (Phase B will hydrate from the cloud row).
class _InMemorySettingsState {
  // TODO(phase-b): persist autoRestThresholdSeconds.
  int autoRestMinutes = _kDefaultAutoRestMinutes;

  // TODO(phase-b): persist defaultTreatment.
  _DefaultTreatment defaultTreatment = _DefaultTreatment.bw;

  // TODO(phase-b): persist defaultBodyFocusOn.
  bool defaultBodyFocusOn = true;

  // TODO(phase-b): persist defaultAudioOn.
  bool defaultAudioOn = false;

  // Web viewer toggles — all default ON so existing plans don't change.
  // TODO(phase-b): persist via a `web_viewer_config` jsonb on plans.
  bool showExerciseTitle = true;
  bool showPractitionerNotes = true;
  bool showProgressPillMatrix = true;
  bool showRepStack = true;
  bool allowClientTreatmentOverride = true;
  bool allowClientRestSkip = true;
}

/// Mounts the plan-settings bottom-sheet.
///
/// Replaces the cloud-download icon's "Save to Photos" affordance on the
/// Studio bottom toolbar — that handler is now reachable from inside
/// the sheet's Plan tab. Three tabs, each capped at one screen of
/// content (no global scrolling-feel that the single-pane layout had):
///
///   Now      — per-session-tweak controls (Pacing rest stepper today,
///              future per-session-only fields land here).
///   Defaults — Display defaults (treatment / body focus / audio) +
///              Web viewer toggles. Phase B persistence wave hydrates.
///   Plan     — Plan actions (Save to Photos / Copy URL / Duplicate /
///              Delete) + Plan info read-only metadata grid.
///
/// Phase A: only the persisted-already fields write through to storage
/// (`preferredRestIntervalSeconds` via [onRestIntervalChanged]). The
/// other sections render but back onto an in-memory state with
/// `TODO(phase-b)` markers for the follow-up agent that wires
/// persistence.
///
/// Sheet always opens on the Now tab (no persistence of last-selected
/// tab — Carl's call).
Future<void> showPlanSettingsSheet({
  required BuildContext context,
  required Session session,
  required String clientName,
  required ValueChanged<int> onRestIntervalChanged,
  required VoidCallback onSaveAllToPhotos,
  required VoidCallback onCopyPlanUrl,
  required VoidCallback onDeletePlan,
  required String createdByLabel,
}) {
  HapticFeedback.selectionClick();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    useSafeArea: true,
    enableDrag: false,
    builder: (sheetCtx) => PlanSettingsSheet(
      session: session,
      clientName: clientName,
      onRestIntervalChanged: onRestIntervalChanged,
      onSaveAllToPhotos: onSaveAllToPhotos,
      onCopyPlanUrl: onCopyPlanUrl,
      onDeletePlan: onDeletePlan,
      createdByLabel: createdByLabel,
    ),
  );
}

/// True when at least one of the persisted plan-settings fields deviates
/// from its default. Drives the coral dot on the toolbar gear icon.
///
/// Phase A scope: only inspects fields that actually persist
/// ([Session.preferredRestIntervalSeconds] for now). When Phase B adds
/// columns for the in-memory toggles, extend this helper — the gear
/// indicator wiring in `studio_bottom_bar.dart` consumes only the bool.
bool settingsDeviateFromDefaults(Session s) {
  final restPref = s.preferredRestIntervalSeconds;
  if (restPref != null && restPref != _kDefaultRestSeconds) return true;
  return false;
}

/// The sheet body. Public for testability; production callers go
/// through [showPlanSettingsSheet].
class PlanSettingsSheet extends StatefulWidget {
  final Session session;
  final String clientName;
  final ValueChanged<int> onRestIntervalChanged;
  final VoidCallback onSaveAllToPhotos;
  final VoidCallback onCopyPlanUrl;
  final VoidCallback onDeletePlan;

  /// Resolved by the host screen — either the practitioner's display
  /// name (when [Session.createdByUserId] resolves) or "—".
  final String createdByLabel;

  const PlanSettingsSheet({
    super.key,
    required this.session,
    required this.clientName,
    required this.onRestIntervalChanged,
    required this.onSaveAllToPhotos,
    required this.onCopyPlanUrl,
    required this.onDeletePlan,
    required this.createdByLabel,
  });

  @override
  State<PlanSettingsSheet> createState() => _PlanSettingsSheetState();
}

class _PlanSettingsSheetState extends State<PlanSettingsSheet> {
  static const double _kDetent = 0.85;

  /// Tab indices.  Sheet always opens on [_kTabNow]; tab selection is
  /// not persisted — reopening resets to Now.
  static const int _kTabNow = 0;
  static const int _kTabDefaults = 1;
  static const int _kTabPlan = 2;

  late final DraggableScrollableController _sheetController;
  late int _restSeconds;
  int _activeTabIndex = _kTabNow;
  final _InMemorySettingsState _local = _InMemorySettingsState();

  @override
  void initState() {
    super.initState();
    _sheetController = DraggableScrollableController();
    _restSeconds =
        widget.session.preferredRestIntervalSeconds ?? _kDefaultRestSeconds;
  }

  @override
  void dispose() {
    _sheetController.dispose();
    super.dispose();
  }

  void _switchTab(int index) {
    if (_activeTabIndex == index) return;
    HapticFeedback.selectionClick();
    setState(() => _activeTabIndex = index);
  }

  // ---------------------------------------------------------------------------
  // Rest stepper — persisted via the host callback. 5s steps, 5..180s.
  // ---------------------------------------------------------------------------

  void _bumpRestSeconds(int delta) {
    final next = (_restSeconds + delta).clamp(5, 180);
    if (next == _restSeconds) return;
    setState(() => _restSeconds = next);
    widget.onRestIntervalChanged(next);
  }

  // ---------------------------------------------------------------------------
  // Plan info helpers
  // ---------------------------------------------------------------------------

  String _formatLastPublished() {
    final dt = widget.session.lastPublishedAt;
    if (dt == null) return '—';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} $hh:$mm';
  }

  String _formatFirstOpened() {
    final dt = widget.session.firstOpenedAt;
    if (dt == null) return '— never —';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '${dt.day} ${months[dt.month - 1]} $hh:$mm';
  }

  String _formatEstimatedDuration() {
    final secs = widget.session.estimatedTotalDurationSeconds;
    if (secs <= 0) return '0 min';
    final minutes = (secs / 60).round();
    return '$minutes min';
  }

  String _formatCreditCost() {
    // Sum non-rest exercise duration the same way upload_service does.
    var nonRestSeconds = 0;
    for (final ex in widget.session.exercises) {
      if (ex.isRest) continue;
      nonRestSeconds += ex.estimatedDurationSeconds;
    }
    final cost = creditCostForDuration(nonRestSeconds);
    return cost == 1 ? '1 credit' : '$cost credits';
  }

  String _formatHeaderSubtitle() {
    final created = widget.session.createdAt;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final date =
        '${created.day} ${months[created.month - 1]} ${created.year}';
    final hh = created.hour.toString().padLeft(2, '0');
    final mm = created.minute.toString().padLeft(2, '0');
    final time = '$hh:$mm';
    final name = widget.clientName.trim().isEmpty
        ? widget.session.clientName.trim()
        : widget.clientName;
    if (name.isEmpty) return '$date $time';
    return '$date $time · client: $name';
  }

  String _planUrlText() {
    return '${AppConfig.webPlayerBaseUrl}/p/${widget.session.id}';
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: _sheetController,
      initialChildSize: _kDetent,
      minChildSize: _kDetent,
      maxChildSize: _kDetent,
      snap: true,
      snapSizes: const [_kDetent],
      expand: false,
      shouldCloseOnMinExtent: false,
      builder: (ctx, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surfaceBase,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
            border: Border(
              top: BorderSide(color: AppColors.surfaceBorder, width: 1),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDragHandle(),
              _buildHeader(),
              _buildTabStrip(),
              Expanded(
                child: _buildActiveTabBody(scrollController),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDragHandle() {
    return SizedBox(
      height: 22,
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: AppColors.surfaceBorder,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 14),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Plan settings',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                    color: AppColors.textOnDark,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _formatHeaderSubtitle(),
                  style: const TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.w400,
                    fontSize: 11.5,
                    color: AppColors.textSecondaryOnDark,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              HapticFeedback.selectionClick();
              Navigator.of(context).pop();
            },
            padding: EdgeInsets.zero,
            iconSize: 22,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            icon: const Icon(
              Icons.close,
              color: AppColors.textSecondaryOnDark,
              size: 22,
            ),
            tooltip: 'Close settings',
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab strip — mirrors exercise_editor_sheet's underline tabs (R-10
  // visual parity inside the editor family). Coral 2px underline, Inter
  // 13/600, dim treatment for inactive tabs.
  // ---------------------------------------------------------------------------

  Widget _buildTabStrip() {
    const tabs = ['Now', 'Defaults', 'Plan'];
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Row(
        children: [
          for (int i = 0; i < tabs.length; i++)
            Expanded(
              child: InkWell(
                onTap: () => _switchTab(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: _activeTabIndex == i
                            ? AppColors.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    tabs[i],
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _activeTabIndex == i
                          ? AppColors.textOnDark
                          : AppColors.textSecondaryOnDark,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActiveTabBody(ScrollController scrollController) {
    switch (_activeTabIndex) {
      case _kTabDefaults:
        return _buildDefaultsTab(scrollController);
      case _kTabPlan:
        return _buildPlanTab(scrollController);
      case _kTabNow:
      default:
        return _buildNowTab(scrollController);
    }
  }

  Widget _buildNowTab(ScrollController scrollController) {
    return SingleChildScrollView(
      controller: scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPacingSection(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildDefaultsTab(ScrollController scrollController) {
    return SingleChildScrollView(
      controller: scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildDisplayDefaultsSection(),
          _buildWebViewerSection(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildPlanTab(ScrollController scrollController) {
    return SingleChildScrollView(
      controller: scrollController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPlanActionsSection(),
          _buildPlanInfoSection(),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Section: Pacing
  // ---------------------------------------------------------------------------

  Widget _buildPacingSection() {
    return _Section(
      label: 'Pacing',
      children: [
        _SettingsStepperRow(
          title: 'Default rest between exercises',
          help: 'Used when an exercise has no per-row override.',
          value: _restSeconds,
          unit: 's',
          onMinus: () => _bumpRestSeconds(-5),
          onPlus: () => _bumpRestSeconds(5),
        ),
        _PhaseBPlaceholder(
          child: _SettingsStepperRow(
            title: 'Auto-insert rest every',
            help:
                'A rest row is suggested whenever the running clock crosses '
                'this threshold. Learned from your drag behaviour by default.',
            value: _local.autoRestMinutes,
            unit: 'min',
            // TODO(phase-b): persist autoRestThresholdSeconds when schema
            // migration lands. Phase A is in-memory only.
            onMinus: () {
              final next = (_local.autoRestMinutes - 1).clamp(1, 60);
              if (next == _local.autoRestMinutes) return;
              setState(() => _local.autoRestMinutes = next);
            },
            onPlus: () {
              final next = (_local.autoRestMinutes + 1).clamp(1, 60);
              if (next == _local.autoRestMinutes) return;
              setState(() => _local.autoRestMinutes = next);
            },
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Section: Display defaults
  // ---------------------------------------------------------------------------

  Widget _buildDisplayDefaultsSection() {
    return _Section(
      label: 'Display defaults',
      labelSuffix: 'applies to new exercises',
      children: [
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Default treatment',
            help: "What new exercises preview as on the client's web viewer.",
            // TODO(phase-b): persist defaultTreatment.
            control: _SettingsChipGroup(
              options: const ['Drawn', 'B&W', 'Colour'],
              selectedIndex: _local.defaultTreatment.index,
              onChanged: (i) => setState(
                () => _local.defaultTreatment = _DefaultTreatment.values[i],
              ),
            ),
          ),
        ),
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Body focus on',
            help:
                'Crisp body, dimmed background. Practitioner-only viewing '
                'default; client can still pick.',
            // TODO(phase-b): persist defaultBodyFocusOn.
            control: _SettingsToggle(
              value: _local.defaultBodyFocusOn,
              onChanged: (v) => setState(() => _local.defaultBodyFocusOn = v),
            ),
          ),
        ),
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Audio on for new exercises',
            help: 'Per-exercise toggle still wins; this is just the default.',
            // TODO(phase-b): persist defaultAudioOn.
            control: _SettingsToggle(
              value: _local.defaultAudioOn,
              onChanged: (v) => setState(() => _local.defaultAudioOn = v),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Section: Web viewer
  // ---------------------------------------------------------------------------

  Widget _buildWebViewerSection() {
    return _Section(
      label: 'Web viewer',
      labelSuffix: 'what your client sees',
      children: [
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Show exercise title above video',
            help: 'The big floating exercise name at the top of the player.',
            // TODO(phase-b): persist via web_viewer_config jsonb.
            control: _SettingsToggle(
              value: _local.showExerciseTitle,
              onChanged: (v) => setState(() => _local.showExerciseTitle = v),
            ),
          ),
        ),
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Show practitioner notes',
            help: 'Notes you wrote on each exercise card.',
            // TODO(phase-b): persist via web_viewer_config jsonb.
            control: _SettingsToggle(
              value: _local.showPractitionerNotes,
              onChanged: (v) =>
                  setState(() => _local.showPractitionerNotes = v),
            ),
          ),
        ),
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Show progress pill matrix',
            help: 'The dotted timeline strip + ETA at the top of the player.',
            // TODO(phase-b): persist via web_viewer_config jsonb.
            control: _SettingsToggle(
              value: _local.showProgressPillMatrix,
              onChanged: (v) =>
                  setState(() => _local.showProgressPillMatrix = v),
            ),
          ),
        ),
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Show rep stack',
            help:
                'Vertical block column on the left edge — one block per rep, '
                'brackets for sets, fill follows the active rep.',
            // TODO(phase-b): persist via web_viewer_config jsonb.
            control: _SettingsToggle(
              value: _local.showRepStack,
              onChanged: (v) => setState(() => _local.showRepStack = v),
            ),
          ),
        ),
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Allow client to override treatment',
            help:
                '"Show me" picker. Off — client sees only the treatment you '
                'prescribed per exercise.',
            // TODO(phase-b): persist via web_viewer_config jsonb.
            control: _SettingsToggle(
              value: _local.allowClientTreatmentOverride,
              onChanged: (v) =>
                  setState(() => _local.allowClientTreatmentOverride = v),
            ),
          ),
        ),
        _PhaseBPlaceholder(
          child: _SettingsRow(
            title: 'Allow client to skip / extend rests',
            help:
                "Off — rest timers run on a fixed clock the client can't "
                'shortcut.',
            // TODO(phase-b): persist via web_viewer_config jsonb.
            control: _SettingsToggle(
              value: _local.allowClientRestSkip,
              onChanged: (v) =>
                  setState(() => _local.allowClientRestSkip = v),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Section: Plan actions
  // ---------------------------------------------------------------------------

  Widget _buildPlanActionsSection() {
    final urlPreview =
        '${AppConfig.webPlayerBaseUrl.replaceFirst('https://', '')}'
        '/p/${widget.session.id.split('-').first}…';
    return _Section(
      label: 'Plan actions',
      children: [
        _SettingsActionRow(
          title: 'Save all videos to camera roll',
          help:
              'Exports each exercise as Drawn / B&W / Colour per your '
              'treatment picks.',
          arrow: Icons.arrow_downward_rounded,
          onTap: () {
            // Close the sheet so any SnackBars from the save flow land
            // on the host scaffold messenger, not the popped one.
            Navigator.of(context).pop();
            widget.onSaveAllToPhotos();
          },
        ),
        _SettingsActionRow(
          title: 'Copy plan share URL',
          helpRich: TextSpan(
            text: urlPreview,
            style: const TextStyle(
              fontFamily: 'JetBrains Mono',
              color: AppColors.primary,
              fontSize: 11.5,
            ),
          ),
          arrow: Icons.copy_rounded,
          onTap: () {
            widget.onCopyPlanUrl();
          },
        ),
        _SettingsActionRow(
          title: 'Duplicate plan',
          help:
              "Coming soon — creates a copy in the same client's session "
              'list, version 1, unpublished.',
          arrow: Icons.chevron_right_rounded,
          enabled: false,
        ),
        _SettingsActionRow(
          title: 'Delete plan',
          help: 'Soft-delete with 7-day undo. Files stay until the cron sweep.',
          arrow: Icons.chevron_right_rounded,
          isDanger: true,
          onTap: () {
            // Close the sheet first so the undo SnackBar from the host's
            // delete handler shows up on the right scaffold messenger.
            Navigator.of(context).pop();
            widget.onDeletePlan();
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Section: Plan info
  // ---------------------------------------------------------------------------

  Widget _buildPlanInfoSection() {
    return _Section(
      label: 'Plan info',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            runSpacing: 12,
            children: [
              _SettingsInfoCell(
                label: 'Version',
                value: 'v${widget.session.version}',
              ),
              _SettingsInfoCell(
                label: 'Last published',
                value: _formatLastPublished(),
              ),
              _SettingsInfoCell(
                label: 'Estimated duration',
                value: _formatEstimatedDuration(),
              ),
              _SettingsInfoCell(
                label: 'Credit cost',
                value: _formatCreditCost(),
              ),
              _SettingsInfoCell(
                label: 'Created by',
                value: widget.createdByLabel.trim().isEmpty
                    ? '—'
                    : widget.createdByLabel,
              ),
              _SettingsInfoCell(
                label: 'First opened',
                value: _formatFirstOpened(),
              ),
              _SettingsInfoCell(
                label: 'Plan URL',
                value: _planUrlText(),
                urlStyle: true,
                full: true,
                onTap: () {
                  widget.onCopyPlanUrl();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Phase B placeholder
// ---------------------------------------------------------------------------

/// Wraps a settings row whose state isn't yet persisted (a `TODO(phase-b)`
/// row). Visually de-emphasises the row, blocks all input, and surfaces a
/// small "Coming soon" chip in the top-right corner so the practitioner
/// understands why their toggles don't survive a sheet reopen.
///
/// The wrapped child still renders fully (so the eventual shape of the
/// row is visible) — interaction is suppressed via [IgnorePointer]. When
/// the matching schema migration lands in Phase B, swap the placeholder
/// out for a direct child render.
class _PhaseBPlaceholder extends StatelessWidget {
  final Widget child;

  const _PhaseBPlaceholder({required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Opacity(
          opacity: 0.45,
          child: IgnorePointer(
            ignoring: true,
            child: child,
          ),
        ),
        Positioned(
          top: 14,
          right: 0,
          child: IgnorePointer(
            ignoring: true,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                border: Border.all(
                  color: AppColors.surfaceBorder,
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text(
                'Coming soon',
                style: TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Reusable inline controls
// ---------------------------------------------------------------------------

/// A single labeled section with a caps-mono header and optional suffix
/// (used for "applies to new exercises", "what your client sees", etc.).
class _Section extends StatelessWidget {
  final String label;
  final String? labelSuffix;
  final List<Widget> children;

  const _Section({
    required this.label,
    required this.children,
    this.labelSuffix,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionLabel(label: label, suffix: labelSuffix),
          ...children,
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final String? suffix;
  const _SectionLabel({required this.label, this.suffix});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RichText(
        text: TextSpan(
          children: [
            TextSpan(
              text: label.toUpperCase(),
              style: const TextStyle(
                fontFamily: 'JetBrains Mono',
                fontSize: 10,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.5,
                color: AppColors.textSecondaryOnDark,
              ),
            ),
            if (suffix != null && suffix!.isNotEmpty)
              TextSpan(
                text: '  ·  ${suffix!.toUpperCase()}',
                style: const TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 1.5,
                  color: AppColors.textSecondaryOnDark,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A standard row: title + help text on the left, control on the right.
class _SettingsRow extends StatelessWidget {
  final String title;
  final String help;
  final Widget control;

  const _SettingsRow({
    required this.title,
    required this.help,
    required this.control,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 13.5,
                      color: AppColors.textOnDark,
                      height: 1.3,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    help,
                    style: const TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w400,
                      fontSize: 11.5,
                      color: AppColors.textSecondaryOnDark,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
          ),
          control,
        ],
      ),
    );
  }
}

/// Stepper row — title + help text + minus/value/plus stepper.
class _SettingsStepperRow extends StatelessWidget {
  final String title;
  final String help;
  final int value;
  final String unit;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _SettingsStepperRow({
    required this.title,
    required this.help,
    required this.value,
    required this.unit,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return _SettingsRow(
      title: title,
      help: help,
      control: _SettingsStepper(
        value: value,
        unit: unit,
        onMinus: onMinus,
        onPlus: onPlus,
      ),
    );
  }
}

class _SettingsToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingsToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onChanged(!value);
      },
      child: Container(
        width: 42,
        height: 24,
        decoration: BoxDecoration(
          color: value
              ? AppColors.primary.withValues(alpha: 0.14)
              : AppColors.surfaceRaised,
          border: Border.all(
            color: value
                ? AppColors.primary.withValues(alpha: 0.38)
                : AppColors.surfaceBorder,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              left: value ? 20 : 2,
              top: 2,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: value
                      ? AppColors.primary
                      : AppColors.textSecondaryOnDark,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsStepper extends StatelessWidget {
  final int value;
  final String unit;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  const _SettingsStepper({
    required this.value,
    required this.unit,
    required this.onMinus,
    required this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.surfaceBorder, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepperButton(
            icon: Icons.remove_rounded,
            onTap: onMinus,
            tooltip: 'Decrease',
          ),
          SizedBox(
            width: 64,
            child: Center(
              child: RichText(
                textAlign: TextAlign.center,
                text: TextSpan(
                  children: [
                    TextSpan(
                      text: '$value',
                      style: const TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: AppColors.textOnDark,
                      ),
                    ),
                    TextSpan(
                      text: unit,
                      style: const TextStyle(
                        fontFamily: 'JetBrains Mono',
                        fontWeight: FontWeight.w400,
                        fontSize: 13,
                        color: AppColors.textSecondaryOnDark,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          _StepperButton(
            icon: Icons.add_rounded,
            onTap: onPlus,
            tooltip: 'Increase',
          ),
        ],
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;

  const _StepperButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 16,
        splashRadius: 16,
        tooltip: tooltip,
        icon: Icon(
          icon,
          color: AppColors.textSecondaryOnDark,
          size: 16,
        ),
        onPressed: () {
          HapticFeedback.selectionClick();
          onTap();
        },
      ),
    );
  }
}

class _SettingsChipGroup extends StatelessWidget {
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _SettingsChipGroup({
    required this.options,
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          _Chip(
            label: options[i],
            selected: i == selectedIndex,
            onTap: () {
              HapticFeedback.selectionClick();
              onChanged(i);
            },
          ),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.14)
              : AppColors.surfaceRaised,
          border: Border.all(
            color: selected
                ? AppColors.primary.withValues(alpha: 0.38)
                : AppColors.surfaceBorder,
            width: 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'Montserrat',
            fontWeight: FontWeight.w600,
            fontSize: 11.5,
            letterSpacing: 0.3,
            color: selected
                ? AppColors.primary
                : AppColors.textSecondaryOnDark,
          ),
        ),
      ),
    );
  }
}

class _SettingsActionRow extends StatelessWidget {
  final String title;
  final String? help;
  final TextSpan? helpRich;
  final IconData arrow;
  final VoidCallback? onTap;
  final bool isDanger;
  final bool enabled;

  const _SettingsActionRow({
    required this.title,
    this.help,
    this.helpRich,
    required this.arrow,
    this.onTap,
    this.isDanger = false,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final titleColor = !enabled
        ? AppColors.textSecondaryOnDark
        : isDanger
            ? AppColors.error
            : AppColors.textOnDark;
    final arrowColor = !enabled
        ? AppColors.textSecondaryOnDark.withValues(alpha: 0.5)
        : AppColors.textSecondaryOnDark;
    final row = Container(
      padding: const EdgeInsets.symmetric(vertical: 13),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.surfaceBorder, width: 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontWeight: FontWeight.w500,
                      fontSize: 13.5,
                      color: titleColor,
                      height: 1.3,
                    ),
                  ),
                  if (helpRich != null) ...[
                    const SizedBox(height: 2),
                    RichText(
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      text: helpRich!,
                    ),
                  ] else if (help != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      help!,
                      style: const TextStyle(
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w400,
                        fontSize: 11.5,
                        color: AppColors.textSecondaryOnDark,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Icon(arrow, size: 20, color: arrowColor),
        ],
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled && onTap != null
          ? () {
              HapticFeedback.selectionClick();
              onTap!();
            }
          : null,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.55,
        child: row,
      ),
    );
  }
}

class _SettingsInfoCell extends StatelessWidget {
  final String label;
  final String value;
  final bool urlStyle;
  final bool full;
  final VoidCallback? onTap;

  const _SettingsInfoCell({
    required this.label,
    required this.value,
    this.urlStyle = false,
    this.full = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final width = full
        ? double.infinity
        : (MediaQuery.of(context).size.width - 40 - 18) / 2;
    final cell = SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 1,
              color: AppColors.textSecondaryOnDark,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'JetBrains Mono',
              fontSize: 12.5,
              color: urlStyle ? AppColors.primary : AppColors.textOnDark,
            ),
            softWrap: true,
            maxLines: full ? 3 : 1,
            overflow: full ? TextOverflow.ellipsis : TextOverflow.ellipsis,
          ),
        ],
      ),
    );
    if (onTap == null) return cell;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap!();
      },
      child: cell,
    );
  }
}
