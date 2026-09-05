import 'package:flutter/material.dart';
import '../constants.dart' show kAppVersionConst;
import '../l10n/app_localizations.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final zh = l.locale.languageCode == 'zh';
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(zh ? '关于' : 'About')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(Icons.bolt_rounded, size: 44, color: cs.primary),
              ),
              const SizedBox(height: 20),
              Text(
                'Nexus',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'v$kAppVersionConst',
                style: TextStyle(fontSize: 15, color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    _infoRow(
                        Icons.code, zh ? 'AI 智能助手' : 'AI Smart Assistant', cs),
                    const Divider(height: 16),
                    _infoRow(Icons.psychology,
                        zh ? '支持多模型 / 联网搜索 / 自主思考' : 'Multi-model / Web search / ReAct', cs),
                    const Divider(height: 16),
                    _infoRow(Icons.extension,
                        zh ? '插件市场 · MCP 协议' : 'Plugin Market · MCP Protocol', cs),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '© 2026 Nexus',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String text, ColorScheme cs) {
    return Row(
      children: [
        Icon(icon, size: 18, color: cs.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 13, color: cs.onSurface)),
        ),
      ],
    );
  }
}