import 'dart:async';

import 'package:flutter/material.dart';

/// Moves the contents of a control while keeping its hit area and shape fixed.
class LoopingControlContent extends StatefulWidget {
  const LoopingControlContent({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.interval,
    this.trigger,
  });

  final Widget child;
  final Duration delay;
  final Duration? interval;
  final Object? trigger;

  @override
  State<LoopingControlContent> createState() => _LoopingControlContentState();
}

class _LoopingControlContentState extends State<LoopingControlContent>
    with SingleTickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );
  Timer? _timer;
  bool _shouldAnimate = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shouldAnimate =
        TickerMode.valuesOf(context).enabled &&
        !MediaQuery.disableAnimationsOf(context);
    if (shouldAnimate == _shouldAnimate) return;
    _shouldAnimate = shouldAnimate;
    if (shouldAnimate) {
      if (widget.interval case final interval?)
        _schedule(interval + widget.delay);
    } else {
      _timer?.cancel();
      _timer = null;
      _motion.reset();
    }
  }

  @override
  void didUpdateWidget(covariant LoopingControlContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_shouldAnimate &&
        widget.interval == null &&
        oldWidget.trigger != widget.trigger) {
      _timer?.cancel();
      if (widget.delay == Duration.zero) {
        _motion.forward(from: 0);
      } else {
        _schedule(widget.delay);
      }
    }
  }

  void _schedule(Duration delay) {
    _timer = Timer(delay, () {
      _timer = null;
      _motion.forward(from: 0);
      if (widget.interval case final interval?) _schedule(interval);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ClipRect(
    child: AnimatedBuilder(
      animation: _motion,
      child: widget.child,
      builder: (context, child) {
        final progress = _motion.value;
        final outgoing = progress < .5;
        final phase = Curves.easeInOutCubic.transform(
          outgoing ? progress * 2 : (1 - progress) * 2,
        );
        return Opacity(
          opacity: 1 - phase,
          alwaysIncludeSemantics: true,
          child: Transform.translate(
            offset: Offset(0, (outgoing ? -1 : 1) * 10 * phase),
            transformHitTests: false,
            child: child,
          ),
        );
      },
    ),
  );
}
