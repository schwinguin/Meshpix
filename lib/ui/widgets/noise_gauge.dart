import 'dart:math';

import 'package:flutter/material.dart';

import '../../models/signal.dart';
import '../theme.dart';

class NoiseGauge extends StatelessWidget {
  const NoiseGauge({
    super.key,
    required this.dbm,
    this.source,
    this.history = const [],
  });

  final int? dbm;
  final String? source;
  final List<int> history;

  @override
  Widget build(BuildContext context) {
    final v = dbm;
    return Card(
      color: const Color(0xFF22232B),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Noise Floor', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text(
              'Grundrauschen am Empfänger. Je kleiner die Zahl, desto leiser — und desto schwächere Signale hörst du noch.',
              style: TextStyle(fontSize: 12, color: meshPaper),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 148,
              width: double.infinity,
              child: CustomPaint(painter: _GaugePainter(v)),
            ),
            if (v != null) ...[
              Center(
                child: Text(
                  '$v dBm · ${noiseQuality(v)}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: meshPaper,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                noiseHint(v),
                style: const TextStyle(fontSize: 13, color: meshPaper),
              ),
              if (source != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Gemessen an $source (Status/Ping), nicht am Handy.',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF9AA0A6),
                    ),
                  ),
                ),
            ] else
              const Text(
                'Noch kein Wert. Pinge einen Repeater oder Kontakt — der schickt sein Rauschen mit.',
                style: TextStyle(color: meshPaper),
              ),
            if (history.length >= 2) ...[
              const SizedBox(height: 12),
              SizedBox(
                height: 36,
                width: double.infinity,
                child: CustomPaint(painter: _SparkPainter(history)),
              ),
              const Text(
                'Verlauf der letzten Pings',
                style: TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter(this.dbm);
  final int? dbm;

  static const _min = -130.0;
  static const _max = -70.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.92);
    final r = min(size.width / 2 - 8, size.height * 0.9);
    const start = pi;
    const sweep = pi;

    void arc(Color color, double from, double to, {double width = 14}) {
      final a0 = start + sweep * ((from - _min) / (_max - _min));
      final a1 = start + sweep * ((to - _min) / (_max - _min));
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: r),
        a0,
        a1 - a0,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..strokeCap = StrokeCap.round,
      );
    }

    arc(const Color(0xFF1E2A22), _min, _max, width: 16);
    arc(meshTeal, -130, -100);
    arc(meshAmber, -100, -88);
    arc(const Color(0xFFE76F51), -88, -70);

    if (dbm != null) {
      final t = ((dbm!.clamp(_min, _max) - _min) / (_max - _min));
      final a = start + sweep * t;
      final tip = Offset(c.dx + cos(a) * (r - 22), c.dy + sin(a) * (r - 22));
      canvas.drawLine(
        c,
        tip,
        Paint()
          ..color = meshPaper
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(c, 5, Paint()..color = meshPaper);
    }

    final labels = <double, String>{-130: '−130', -100: '−100', -70: '−70'};
    final tp = TextPainter(textDirection: TextDirection.ltr);
    labels.forEach((v, t) {
      final a = start + sweep * ((v - _min) / (_max - _min));
      final p = Offset(c.dx + cos(a) * (r + 2), c.dy + sin(a) * (r + 2) - 12);
      tp
        ..text = TextSpan(
          text: t,
          style: const TextStyle(fontSize: 10, color: Color(0xFF9AA0A6)),
        )
        ..layout();
      tp.paint(canvas, Offset(p.dx - tp.width / 2, p.dy));
    });
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) => old.dbm != dbm;
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.values);
  final List<int> values;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var minV = values.first.toDouble();
    var maxV = values.first.toDouble();
    for (final v in values) {
      minV = min(minV, v.toDouble());
      maxV = max(maxV, v.toDouble());
    }
    if ((maxV - minV).abs() < 2) {
      maxV += 2;
      minV -= 2;
    }
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = size.height * (1 - (values[i] - minV) / (maxV - minV));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = meshTeal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.values != values;
}
