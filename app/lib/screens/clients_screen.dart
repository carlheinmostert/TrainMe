import 'package:flutter/material.dart';

import '../models/client.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../theme.dart';
import '../widgets/client_consent_sheet.dart';

/// Minimum-viable "Your clients" screen. Lists every client that belongs
/// to the signed-in practitioner's active practice along with their
/// three-treatment viewing state.
///
/// The indicator next to each row is a three-dot glyph:
///  - dot 1 (Line) — always solid coral (platform baseline).
///  - dot 2 (B&W) — solid coral when `grayscaleAllowed`, outlined otherwise.
///  - dot 3 (Original) — solid coral when `colourAllowed`, outlined otherwise.
///
/// Tapping a row opens the consent sheet so the practitioner can flip
/// toggles. Empty state reads: "You'll see clients here once you publish
/// a plan for them." — which matches the backend assumption that client
/// rows are minted on first publish.
class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});

  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  List<PracticeClient> _clients = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final practiceId = AuthService.instance.currentPracticeId.value;
    if (practiceId == null) {
      setState(() {
        _loading = false;
        _error = 'No practice selected yet.';
      });
      return;
    }
    final clients = await ApiClient.instance.listPracticeClients(practiceId);
    if (!mounted) return;
    setState(() {
      _clients = clients;
      _loading = false;
    });
  }

  Future<void> _openConsent(PracticeClient client) async {
    final updated = await showClientConsentSheet(context, client: client);
    if (updated != null && mounted) {
      setState(() {
        _clients = _clients
            .map((c) => c.id == updated.id ? updated : c)
            .toList(growable: false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surfaceBg,
      appBar: AppBar(
        title: const Text('Your clients'),
        backgroundColor: AppColors.surfaceBg,
        foregroundColor: AppColors.textOnDark,
        elevation: 0,
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.textSecondaryOnDark,
              fontFamily: 'Inter',
              fontSize: 14,
            ),
          ),
        ),
      );
    }
    if (_clients.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            "You'll see clients here once you publish a plan for them.",
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.textSecondaryOnDark,
              fontFamily: 'Inter',
              fontSize: 15,
              height: 1.5,
            ),
          ),
        ),
      );
    }
    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _clients.length,
        separatorBuilder: (_, _) => const Divider(
          height: 1,
          color: AppColors.surfaceBorder,
        ),
        itemBuilder: (context, i) => _ClientRow(
          client: _clients[i],
          onTap: () => _openConsent(_clients[i]),
        ),
      ),
    );
  }
}

class _ClientRow extends StatelessWidget {
  final PracticeClient client;
  final VoidCallback onTap;

  const _ClientRow({required this.client, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                client.name.isEmpty ? 'Unnamed client' : client.name,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textOnDark,
                ),
              ),
            ),
            _TreatmentDots(
              line: client.lineAllowed,
              grayscale: client.grayscaleAllowed,
              colour: client.colourAllowed,
            ),
            const SizedBox(width: 12),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: AppColors.textSecondaryOnDark,
            ),
          ],
        ),
      ),
    );
  }
}

/// Three-dot viewing-state glyph. Solid coral dot = treatment enabled;
/// outlined dot = treatment off. First dot is line drawing — always on.
class _TreatmentDots extends StatelessWidget {
  final bool line;
  final bool grayscale;
  final bool colour;

  const _TreatmentDots({
    required this.line,
    required this.grayscale,
    required this.colour,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _dot(filled: line),
        const SizedBox(width: 6),
        _dot(filled: grayscale),
        const SizedBox(width: 6),
        _dot(filled: colour),
      ],
    );
  }

  Widget _dot({required bool filled}) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? AppColors.primary : Colors.transparent,
        border: Border.all(
          color: filled ? AppColors.primary : AppColors.textSecondaryOnDark,
          width: 1.5,
        ),
      ),
    );
  }
}
