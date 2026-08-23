import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../geo/los.dart';
import '../theme.dart';

class LosChart extends StatelessWidget {
  const LosChart({super.key, required this.result, this.height = 196});

  final LosResult result;
  final double height;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: ColoredBox(
        color: const Color(0xFF12131A),
        child: SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _LosPainter(result)),
        ),
      ),
    );
  }
}

class _LosPainter extends CustomPainter {
  _LosPainter(this.result);
  final LosResult result;

  @override
  void paint(Canvas canvas, Size size) {
    final samples = result.samples;
    if (samples.isEmpty || size.width < 8) return;
    final padL = 44.0;
    final padR = 16.0;
    final padT = 22.0;
    final padB = 28.0;
    final w = size.width - padL - padR;
    final h = size.height - padT - padB;

    var minY = samples.first.obstacleM;
    var maxY = samples.first.losM;
    for (final s in samples) {
      minY = min(minY, min(s.obstacleM, s.losM - s.fresnelM));
      maxY = max(maxY, max(s.losM + s.fresnelM * 0.15, s.obstacleM));
    }
    if ((maxY - minY).abs() < 8) {
      maxY += 20;
      minY -= 8;
    }
    minY -= (maxY - minY) * 0.08;
    maxY += (maxY - minY) * 0.12;

    double xAt(int i) => padL + w * i / max(1, samples.length - 1);
    double yAt(double m) => padT + h * (1 - (m - minY) / (maxY - minY));

    final terrain = Path()
      ..moveTo(xAt(0), padT + h)
      ..lineTo(xAt(0), yAt(samples.first.obstacleM));
    for (var i = 1; i < samples.length; i++) {
      terrain.lineTo(xAt(i), yAt(samples[i].obstacleM));
    }
    terrain
      ..lineTo(xAt(samples.length - 1), padT + h)
      ..close();

    canvas.drawPath(
      terrain,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(0, yAt(maxY)),
          Offset(0, padT + h),
          const [Color(0xFF2A4A3A), Color(0xFF1A241C)],
        ),
    );
    canvas.drawPath(
      terrain,
      Paint()
        ..color = const Color(0xFF3D6B54)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    final fresnel = Path();
    for (var i = 0; i < samples.length; i++) {
      final p = Offset(
        xAt(i),
        yAt(samples[i].losM - 0.6 * samples[i].fresnelM),
      );
      if (i == 0) {
        fresnel.moveTo(p.dx, p.dy);
      } else {
        fresnel.lineTo(p.dx, p.dy);
      }
    }
    for (var i = samples.length - 1; i >= 0; i--) {
      fresnel.lineTo(xAt(i), yAt(samples[i].losM + 0.15 * samples[i].fresnelM));
    }
    fresnel.close();
    canvas.drawPath(
      fresnel,
      Paint()..color = meshAmber.withValues(alpha: 0.16),
    );

    final los = Path()..moveTo(xAt(0), yAt(samples.first.losM));
    for (var i = 1; i < samples.length; i++) {
      los.lineTo(xAt(i), yAt(samples[i].losM));
    }
    final losColor = switch (result.verdict) {
      LosVerdict.clear => meshTeal,
      LosVerdict.marginal => meshAmber,
      LosVerdict.blocked => const Color(0xFFE76F51),
      LosVerdict.noFix => meshPaper,
    };
    canvas.drawPath(
      los,
      Paint()
        ..color = losColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round,
    );

    var worstI = 0;
    for (var i = 1; i < samples.length; i++) {
      if (samples[i].clearanceM < samples[worstI].clearanceM) worstI = i;
    }
    if (result.verdict == LosVerdict.blocked ||
        result.verdict == LosVerdict.marginal) {
      final p = Offset(xAt(worstI), yAt(samples[worstI].obstacleM));
      canvas.drawCircle(p, 5, Paint()..color = losColor);
    }

    final tip = TextPainter(textDirection: TextDirection.ltr);
    void label(
      String t,
      Offset o, {
      Color color = meshPaper,
      double size = 10,
    }) {
      tip
        ..text = TextSpan(
          text: t,
          style: TextStyle(
            color: color,
            fontSize: size,
            fontWeight: FontWeight.w600,
          ),
        )
        ..layout();
      tip.paint(canvas, o);
    }

    label(result.fromName, Offset(padL, 4), color: meshTeal);
    final endW = _measure(result.toName);
    label(result.toName, Offset(size.width - padR - endW, 4), color: meshAmber);
    label('0', Offset(padL, padT + h + 6));
    label(
      '${(result.distanceM / 1000).toStringAsFixed(1)} km',
      Offset(padL + w / 2 - 18, padT + h + 6),
    );
    label('${maxY.round()} m', Offset(6, padT), size: 9);
    label('${minY.round()} m', Offset(6, padT + h - 10), size: 9);

    canvas.drawCircle(
      Offset(xAt(0), yAt(samples.first.losM)),
      4,
      Paint()..color = meshTeal,
    );
    canvas.drawCircle(
      Offset(xAt(samples.length - 1), yAt(samples.last.losM)),
      4,
      Paint()..color = meshAmber,
    );
  }

  double _measure(String t) {
    final tip = TextPainter(
      text: TextSpan(text: t, style: const TextStyle(fontSize: 10)),
      textDirection: TextDirection.ltr,
    )..layout();
    return tip.width;
  }

  @override
  bool shouldRepaint(covariant _LosPainter old) => old.result != result;
}
