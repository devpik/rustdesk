import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class QuantixUpdateInfo {
  final String version;
  final String downloadUrl;
  final String sha256;
  final String notes;
  final int sizeBytes;

  const QuantixUpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.sha256,
    required this.notes,
    required this.sizeBytes,
  });
}

class QuantixUpdater {
  static const String manifestUrl =
      'https://remote.2048quantix.com/downloads/manifest.json';
  static const String fallbackWebsiteUrl = 'https://remote.2048quantix.com';
  static const String allowedHost = 'remote.2048quantix.com';

  static List<int> _parseSemver(String raw) {
    var v = raw.trim().toLowerCase();
    if (v.startsWith('v')) {
      v = v.substring(1);
    }
    final plusIdx = v.indexOf('+');
    if (plusIdx != -1) v = v.substring(0, plusIdx);
    final dashIdx = v.indexOf('-');
    if (dashIdx != -1) v = v.substring(0, dashIdx);
    final parts = v.split('.');
    return List<int>.generate(3, (i) {
      if (i >= parts.length) return 0;
      return int.tryParse(parts[i].trim()) ?? 0;
    });
  }

  static bool isNewerVersion(String remoteVer, String currentVer) {
    final r = _parseSemver(remoteVer);
    final c = _parseSemver(currentVer);
    for (int i = 0; i < 3; i++) {
      if (r[i] > c[i]) return true;
      if (r[i] < c[i]) return false;
    }
    return false;
  }

  static Future<QuantixUpdateInfo?> fetchLatestUpdate({
    required String currentVersion,
  }) async {
    final res = await http
        .get(Uri.parse(manifestUrl))
        .timeout(const Duration(seconds: 6));
    if (res.statusCode != 200) {
      throw Exception('HTTP ${res.statusCode}');
    }
    final data = jsonDecode(res.body);
    if (data is! Map) {
      throw Exception('Manifesto inválido');
    }
    final remoteVer = (data['version'] ?? '').toString().trim();
    final downloadUrl = (data['download_url'] ?? '').toString().trim();
    final sha256 = (data['sha256'] ?? '').toString().trim().toLowerCase();
    final notes = (data['notes'] ?? '').toString().trim();
    final sizeBytes = int.tryParse((data['size_bytes'] ?? '0').toString()) ?? 0;

    if (remoteVer.isEmpty || downloadUrl.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(downloadUrl);
    if (uri == null || uri.scheme != 'https' || uri.host != allowedHost) {
      throw Exception('URL de atualização não autorizada');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw Exception('Hash SHA-256 ausente ou inválido no manifesto');
    }
    if (!isNewerVersion(remoteVer, currentVersion)) {
      return null;
    }
    return QuantixUpdateInfo(
      version: remoteVer,
      downloadUrl: downloadUrl,
      sha256: sha256,
      notes: notes,
      sizeBytes: sizeBytes,
    );
  }

  static Future<String> computeFileSha256Windows(String filePath) async {
    final res = await Process.run('certutil', ['-hashfile', filePath, 'SHA256']);
    if (res.exitCode != 0) {
      throw Exception('Falha ao executar certutil (${res.exitCode})');
    }
    final lines = res.stdout.toString().split(RegExp(r'\r?\n'));
    for (final line in lines) {
      final clean = line.replaceAll(RegExp(r'\s+'), '').toLowerCase();
      if (RegExp(r'^[a-f0-9]{64}$').hasMatch(clean)) {
        return clean;
      }
    }
    throw Exception('Não foi possível extrair SHA-256 do arquivo baixado');
  }

  static Future<void> _openExternalUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  static Future<void> startQuantixUpdateFlow(
    BuildContext context,
    QuantixUpdateInfo info,
  ) async {
    if (!isWindows || !bind.mainIsInstalled()) {
      await _openExternalUrl(info.downloadUrl);
      return;
    }

    var cancelled = false;
    var started = false;
    var finished = false;
    var failed = false;
    var statusText = 'Conectando ao servidor Quantix...';
    double? progress;
    String? errorMessage;

    final tempDir = Directory.systemTemp.path;
    final cleanVer = info.version.replaceAll(RegExp(r'[^0-9A-Za-z._-]'), '_');
    final destPath = '$tempDir${Platform.pathSeparator}QuantixRemoto-update-v$cleanVer.exe';

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            if (!started) {
              started = true;
              Future<void>(() async {
                final client = http.Client();
                IOSink? sink;
                try {
                  final req = http.Request('GET', Uri.parse(info.downloadUrl));
                  final streamed =
                      await client.send(req).timeout(const Duration(seconds: 20));
                  if (streamed.statusCode != 200) {
                    throw Exception('Erro HTTP ${streamed.statusCode} ao baixar');
                  }
                  final total = streamed.contentLength ??
                      (info.sizeBytes > 0 ? info.sizeBytes : 0);
                  final outFile = File(destPath);
                  if (await outFile.exists()) {
                    await outFile.delete();
                  }
                  sink = outFile.openWrite();
                  var received = 0;
                  var lastUiUpdate = DateTime.now();

                  await for (final chunk in streamed.stream) {
                    if (cancelled) {
                      break;
                    }
                    sink.add(chunk);
                    received += chunk.length;
                    final now = DateTime.now();
                    if (now.difference(lastUiUpdate).inMilliseconds >= 120 ||
                        (total > 0 && received >= total)) {
                      lastUiUpdate = now;
                      if (!cancelled && ctx.mounted) {
                        final recMb = (received / (1024 * 1024)).toStringAsFixed(1);
                        final totMb = total > 0
                            ? ' / ${(total / (1024 * 1024)).toStringAsFixed(1)} MB'
                            : ' MB';
                        setDialogState(() {
                          progress = total > 0 ? (received / total).clamp(0.0, 1.0) : null;
                          statusText = 'Baixando Quantix Remoto v${info.version} ($recMb$totMb)...';
                        });
                      }
                    }
                  }
                  await sink.flush();
                  await sink.close();
                  sink = null;

                  if (cancelled) {
                    if (await outFile.exists()) {
                      await outFile.delete().catchError((_) => outFile);
                    }
                    return;
                  }

                  if (ctx.mounted) {
                    setDialogState(() {
                      progress = null;
                      statusText = 'Verificando integridade digital (SHA-256)...';
                    });
                  }
                  final actualSha = await computeFileSha256Windows(destPath);
                  if (actualSha != info.sha256.toLowerCase()) {
                    if (await outFile.exists()) {
                      await outFile.delete().catchError((_) => outFile);
                    }
                    throw Exception(
                      'Falha na verificação de integridade SHA-256. Baixe novamente pelo site oficial.',
                    );
                  }

                  if (ctx.mounted) {
                    setDialogState(() {
                      progress = 1.0;
                      statusText =
                          'Iniciando atualização... O Quantix Remoto será reiniciado em instantes.';
                    });
                  }
                  try {
                    await rustDeskWinManager.closeAllSubWindows();
                  } catch (_) {}

                  await Process.start(
                    destPath,
                    ['--update'],
                    mode: ProcessStartMode.detached,
                  );

                  finished = true;
                  if (ctx.mounted) {
                    setDialogState(() {});
                  }
                  await Future.delayed(const Duration(seconds: 2));
                  if (dialogCtx.mounted) {
                    Navigator.of(dialogCtx).pop();
                  }
                } catch (e) {
                  try {
                    await sink?.close();
                  } catch (_) {}
                  failed = true;
                  errorMessage = e.toString();
                  if (!cancelled && ctx.mounted) {
                    setDialogState(() {
                      progress = null;
                      statusText = 'Não foi possível concluir a atualização automática.';
                    });
                  }
                } finally {
                  client.close();
                }
              });
            }

            return AlertDialog(
              title: Text(
                failed
                    ? 'Erro na Atualização'
                    : 'Atualizando para v${info.version}',
              ),
              content: SizedBox(
                width: 390,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(statusText),
                    const SizedBox(height: 14),
                    if (!failed)
                      LinearProgressIndicator(value: progress),
                    if (failed && errorMessage != null) ...[
                      const SizedBox(height: 6),
                      SelectableText(
                        errorMessage!,
                        style: const TextStyle(fontSize: 12, color: Colors.redAccent),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                if (failed)
                  TextButton(
                    onPressed: () {
                      Navigator.of(dialogCtx).pop();
                      _openExternalUrl(info.downloadUrl);
                    },
                    child: const Text('Baixar no Navegador'),
                  ),
                TextButton(
                  onPressed: finished
                      ? () => Navigator.of(dialogCtx).pop()
                      : () {
                          cancelled = true;
                          Navigator.of(dialogCtx).pop();
                        },
                  child: Text(finished ? 'Fechar' : 'Cancelar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static Future<void> checkForUpdatesInteractive(BuildContext context) async {
    var dialogOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const AlertDialog(
        content: Row(
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Verificando atualizações do Quantix Remoto...')),
          ],
        ),
      ),
    ).then((_) {
      dialogOpen = false;
    });

    try {
      final currentVer = await bind.mainGetVersion();
      final update = await fetchLatestUpdate(currentVersion: currentVer);
      if (dialogOpen && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (!context.mounted) return;

      if (update == null) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF10B981)),
                SizedBox(width: 8),
                Text('Quantix Remoto atualizado'),
              ],
            ),
            content: Text(
              'Você já está utilizando a versão mais recente (v$currentVer).',
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }

      final canAutoUpdate = isWindows && bind.mainIsInstalled();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.system_update_alt, color: Color(0xFF0EA5E9)),
              const SizedBox(width: 8),
              Text('Nova versão disponível (v${update.version})'),
            ],
          ),
          content: SizedBox(
            width: 390,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Versão atual: v$currentVer  ➔  Nova: v${update.version}'),
                if (update.notes.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    update.notes,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Agora não'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                startQuantixUpdateFlow(context, update);
              },
              child: Text(canAutoUpdate
                  ? 'Atualizar Agora'
                  : 'Baixar v${update.version}'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (dialogOpen && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Falha ao verificar atualizações'),
          content: Text(
            'Não foi possível consultar o servidor remote.2048quantix.com.\n\nDetalhes: $e',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _openExternalUrl(fallbackWebsiteUrl);
              },
              child: const Text('Abrir Site'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Fechar'),
            ),
          ],
        ),
      );
    }
  }
}
