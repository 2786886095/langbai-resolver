import 'package:flutter/material.dart';

import '../models/download_record.dart';
import '../models/media_models.dart';
import '../theme/langbai_theme.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({
    super.key,
    required this.records,
    required this.onClear,
    required this.onRetry,
  });

  final List<DownloadRecord> records;
  final VoidCallback onClear;
  final ValueChanged<DownloadRecord> onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(26, 28, 26, 42),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '下载任务',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (records.isNotEmpty)
                      TextButton.icon(
                        onPressed: onClear,
                        icon: const Icon(Icons.delete_sweep_outlined),
                        label: const Text('清空历史'),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '查看解析、转换和下载进度',
                  style: TextStyle(color: context.palette.textMuted),
                ),
                const SizedBox(height: 24),
                Expanded(
                  child: records.isEmpty
                      ? _EmptyDownloads()
                      : LangbaiCard(
                          child: ListView.separated(
                            itemCount: records.length,
                            separatorBuilder: (_, _) => Divider(
                              height: 1,
                              color: context.palette.border,
                            ),
                            itemBuilder: (context, index) => _DownloadTile(
                              record: records[index],
                              onRetry: () => onRetry(records[index]),
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyDownloads extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return LangbaiCard(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_download_outlined,
                size: 52,
                color: context.palette.textMuted,
              ),
              const SizedBox(height: 16),
              const Text(
                '暂无下载任务',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                '解析链接并选择资源后，任务会显示在这里',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.palette.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.record, required this.onRetry});

  final DownloadRecord record;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final job = record.job;
    final stateLabel = switch (job.state) {
      JobState.queued => '等待中',
      JobState.running => '下载中',
      JobState.completed => '已完成',
      JobState.failed => '失败',
      JobState.cancelled => '已取消',
    };
    final stateColor = switch (job.state) {
      JobState.completed => context.palette.success,
      JobState.failed => Theme.of(context).colorScheme.error,
      JobState.cancelled => context.palette.textMuted,
      _ => Theme.of(context).colorScheme.primary,
    };
    final metrics = _transferSummary(job);
    final retry =
        (job.state == JobState.failed || job.state == JobState.cancelled) &&
        record.sourceUrl.isNotEmpty;
    final icon = Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.downloading_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
    );
    Widget details({required bool showProgress}) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          record.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          '${record.platform} · ${record.optionLabel}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.palette.textMuted, fontSize: 12),
        ),
        if (showProgress) ...[
          const SizedBox(height: 9),
          LinearProgressIndicator(
            minHeight: 5,
            value: job.state == JobState.queued ? null : job.progress,
            borderRadius: BorderRadius.circular(8),
          ),
        ],
        if (metrics.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            metrics,
            key: ValueKey('download-metrics-${job.id}'),
            style: TextStyle(color: context.palette.textMuted, fontSize: 12),
          ),
        ],
        if (job.error != null && job.error!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            job.error!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    Expanded(child: details(showProgress: false)),
                  ],
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  minHeight: 5,
                  value: job.state == JobState.queued ? null : job.progress,
                  borderRadius: BorderRadius.circular(8),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Text(
                      '$stateLabel · ${(job.progress * 100).round()}%',
                      style: TextStyle(
                        color: stateColor,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (retry)
                      TextButton(onPressed: onRetry, child: const Text('重新解析')),
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: 14),
              Expanded(child: details(showProgress: true)),
              const SizedBox(width: 18),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    stateLabel,
                    style: TextStyle(
                      color: stateColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    '${(job.progress * 100).round()}%',
                    style: TextStyle(color: context.palette.textMuted),
                  ),
                  if (retry)
                    TextButton(onPressed: onRetry, child: const Text('重新解析')),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

String _transferSummary(DownloadJob job) {
  final parts = <String>[];
  if (job.downloadedBytes != null) {
    parts.add(
      job.totalBytes == null
          ? _humanBytes(job.downloadedBytes!)
          : '${_humanBytes(job.downloadedBytes!)} / ${_humanBytes(job.totalBytes!)}',
    );
  }
  final speed = job.speedBytesPerSecond ?? job.averageSpeedBytesPerSecond;
  if (speed != null && speed > 0) parts.add('${_humanBytes(speed.round())}/s');
  if (job.etaSeconds != null) parts.add('约 ${job.etaSeconds}s');
  return parts.join(' · ');
}

String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib >= 100 ? 0 : 1)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(mib >= 100 ? 0 : 1)} MB';
  return '${(mib / 1024).toStringAsFixed(2)} GB';
}
