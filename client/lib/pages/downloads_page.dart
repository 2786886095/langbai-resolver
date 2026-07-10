import 'package:flutter/material.dart';

import '../models/download_record.dart';
import '../models/media_models.dart';
import '../theme/langbai_theme.dart';

class DownloadsPage extends StatelessWidget {
  const DownloadsPage({super.key, required this.records});

  final List<DownloadRecord> records;

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
                Text(
                  '下载任务',
                  style: Theme.of(context)
                      .textTheme
                      .headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 6),
                Text('查看解析、转换和下载进度',
                    style: TextStyle(color: context.palette.textMuted)),
                const SizedBox(height: 24),
                Expanded(
                  child: records.isEmpty
                      ? _EmptyDownloads()
                      : Card(
                          child: ListView.separated(
                            itemCount: records.length,
                            separatorBuilder: (_, __) => Divider(
                                height: 1, color: context.palette.border),
                            itemBuilder: (context, index) =>
                                _DownloadTile(record: records[index]),
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
    return Card(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_download_outlined,
                  size: 52, color: context.palette.textMuted),
              const SizedBox(height: 16),
              const Text('暂无下载任务',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              Text('解析链接并选择资源后，任务会显示在这里',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.palette.textMuted)),
            ],
          ),
        ),
      ),
    );
  }
}

class _DownloadTile extends StatelessWidget {
  const _DownloadTile({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    final job = record.job;
    final stateLabel = switch (job.state) {
      JobState.queued => '等待中',
      JobState.running => '下载中',
      JobState.completed => '已完成',
      JobState.failed => '失败',
    };
    final stateColor = switch (job.state) {
      JobState.completed => context.palette.success,
      JobState.failed => Theme.of(context).colorScheme.error,
      _ => Theme.of(context).colorScheme.primary,
    };
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.downloading_rounded,
                color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(record.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('${record.platform} · ${record.optionLabel}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: context.palette.textMuted, fontSize: 12)),
                const SizedBox(height: 9),
                LinearProgressIndicator(
                  minHeight: 5,
                  value: job.state == JobState.queued ? null : job.progress,
                  borderRadius: BorderRadius.circular(8),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(stateLabel,
                  style: TextStyle(
                      color: stateColor, fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              Text('${(job.progress * 100).round()}%',
                  style: TextStyle(color: context.palette.textMuted)),
            ],
          ),
        ],
      ),
    );
  }
}
