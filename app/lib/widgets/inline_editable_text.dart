import 'package:flutter/material.dart';
import '../theme.dart';

/// A tappable text field that renders as a dashed-underline label until the
/// user taps to edit. Commits on submit or when focus is lost.
///
/// Used for both the session client name (AppBar title) and per-exercise
/// names. Visual treatment matches the dark-mode inline-editing pattern:
/// small dashed grey underline, primary text colour.
class InlineEditableText extends StatefulWidget {
  final String initialValue;
  final ValueChanged<String> onCommit;
  final TextStyle? textStyle;
  final String? hintText;

  const InlineEditableText({
    super.key,
    required this.initialValue,
    required this.onCommit,
    this.textStyle,
    this.hintText,
  });

  @override
  State<InlineEditableText> createState() => _InlineEditableTextState();
}

class _InlineEditableTextState extends State<InlineEditableText> {
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  bool _isEditing = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode.addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant InlineEditableText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isEditing && oldWidget.initialValue != widget.initialValue) {
      _controller.text = widget.initialValue;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus && _isEditing) {
      _commit();
    }
  }

  void _startEditing() {
    _controller.text = widget.initialValue;
    setState(() => _isEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  void _commit() {
    final newValue = _controller.text.trim();
    if (newValue.isNotEmpty && newValue != widget.initialValue) {
      widget.onCommit(newValue);
    }
    setState(() => _isEditing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return TextField(
        controller: _controller,
        focusNode: _focusNode,
        style: widget.textStyle,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          border: InputBorder.none,
          isDense: true,
          contentPadding: EdgeInsets.zero,
          hintText: widget.hintText,
        ),
        onSubmitted: (_) => _commit(),
      );
    }

    return GestureDetector(
      onTap: _startEditing,
      child: CustomPaint(
        painter: _DashedUnderlinePainter(color: AppColors.grey500),
        child: Text(
          widget.initialValue,
          style: widget.textStyle,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// Wraps [child] in the same dashed underline affordance used by
/// [InlineEditableText]. Apply anywhere a value will trigger a popup or
/// pill editor (Plan cells, Settings summaries, rest bar duration).
class DashedUnderline extends StatelessWidget {
  final Widget child;
  final Color color;

  const DashedUnderline({
    super.key,
    required this.child,
    this.color = AppColors.grey500,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedUnderlinePainter(color: color),
      child: child,
    );
  }
}

/// Dashed underline painter — used for tappable editable names.
class _DashedUnderlinePainter extends CustomPainter {
  final Color color;
  _DashedUnderlinePainter({this.color = Colors.grey});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    double startX = 0;
    const dashWidth = 4.0;
    const dashGap = 3.0;

    while (startX < size.width) {
      canvas.drawLine(
        Offset(startX, size.height),
        Offset(startX + dashWidth, size.height),
        paint,
      );
      startX += dashWidth + dashGap;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
