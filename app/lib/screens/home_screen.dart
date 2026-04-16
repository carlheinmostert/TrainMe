import 'package:flutter/material.dart';
import '../models/session.dart';
import '../services/local_storage_service.dart';
import 'session_capture_screen.dart';
import 'plan_editor_screen.dart';

/// Landing screen — the first thing the bio sees.
///
/// Shows a prominent "New Session" button and a list of recent unsent
/// sessions. Tapping a recent session goes to the plan editor so the
/// bio can pick up where she left off.
class HomeScreen extends StatefulWidget {
  final LocalStorageService storage;

  const HomeScreen({super.key, required this.storage});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Session> _sessions = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  Future<void> _loadSessions() async {
    final sessions = await widget.storage.getActiveSessions();
    setState(() {
      _sessions = sessions;
      _loading = false;
    });
  }

  /// Show a dialog to get the client name, then navigate to capture.
  Future<void> _startNewSession() async {
    final clientName = await showDialog<String>(
      context: context,
      builder: (context) => _ClientNameDialog(),
    );

    if (clientName == null || clientName.trim().isEmpty) return;
    if (!mounted) return;

    final session = Session.create(clientName: clientName.trim());
    await widget.storage.saveSession(session);

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SessionCaptureScreen(
          session: session,
          storage: widget.storage,
        ),
      ),
    );

    // Refresh the list when returning from capture
    _loadSessions();
  }

  /// Navigate to the plan editor for an existing session.
  Future<void> _openSession(Session session) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlanEditorScreen(
          session: session,
          storage: widget.storage,
        ),
      ),
    );

    // Refresh in case the session was sent or deleted
    _loadSessions();
  }

  Future<void> _deleteSession(Session session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text(
          'This will permanently delete the session for '
          '${session.clientName} and all its captures.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.storage.deleteSession(session.id);
      _loadSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Raidme',
          style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    return Column(
      children: [
        const SizedBox(height: 32),

        // Prominent "New Session" button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: SizedBox(
            width: double.infinity,
            height: 56,
            child: FilledButton.icon(
              onPressed: _startNewSession,
              icon: const Icon(Icons.add_a_photo_outlined, size: 24),
              label: const Text(
                'New Session',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.black87,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ),

        const SizedBox(height: 32),

        // Recent sessions header
        if (_sessions.isNotEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Recent Sessions',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.black54,
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ),

        const SizedBox(height: 8),

        // Session list
        Expanded(
          child: _sessions.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) =>
                      _buildSessionCard(_sessions[index]),
                ),
        ),
      ],
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.fitness_center_outlined, size: 64, color: Colors.black26),
          SizedBox(height: 16),
          Text(
            'No sessions yet',
            style: TextStyle(fontSize: 16, color: Colors.black38),
          ),
          SizedBox(height: 4),
          Text(
            'Tap New Session to get started',
            style: TextStyle(fontSize: 14, color: Colors.black26),
          ),
        ],
      ),
    );
  }

  Widget _buildSessionCard(Session session) {
    final exerciseCount = session.exercises.length;
    final pending = session.pendingConversions;

    return Card(
      elevation: 0,
      color: Colors.grey.shade50,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        title: Text(
          session.clientName,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '$exerciseCount exercise${exerciseCount == 1 ? '' : 's'}'
          '${pending > 0 ? ' ($pending converting...)' : ''}',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
        trailing: IconButton(
          icon: Icon(Icons.delete_outline, color: Colors.grey.shade400),
          onPressed: () => _deleteSession(session),
        ),
        onTap: () => _openSession(session),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Client name dialog — shown when starting a new session
// ---------------------------------------------------------------------------

class _ClientNameDialog extends StatefulWidget {
  @override
  State<_ClientNameDialog> createState() => _ClientNameDialogState();
}

class _ClientNameDialogState extends State<_ClientNameDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Client name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          hintText: 'e.g. Sarah Johnson',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Start'),
        ),
      ],
    );
  }

  void _submit() {
    Navigator.pop(context, _controller.text);
  }
}
