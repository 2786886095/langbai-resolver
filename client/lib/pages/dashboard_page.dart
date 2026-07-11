import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/download_record.dart';
import '../models/media_models.dart';
import '../theme/langbai_theme.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.recentDownloads,
    required this.onParseManual,
    required this.onOpenTool,
    required this.onShowAllTasks,
  });

  final List<DownloadRecord> recentDownloads;
  final ValueChanged<String> onParseManual;
  final ValueChanged<String> onOpenTool;
  final VoidCallback onShowAllTasks;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final _manualController = TextEditingController();

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) return;
    _manualController.text = data!.text!.trim();
  }

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour < 6
        ? '夜深了'
        : hour < 11
        ? '早上好'
        : hour < 14
        ? '中午好'
        : hour < 18
        ? '下午好'
        : '晚上好';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(26, 28, 26, 42),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '$greeting，欢迎使用 langbai解析',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.4,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '手动粘贴链接开始；也可在设置中开启剪贴板识别提示',
                  style: TextStyle(color: context.palette.textMuted),
                ),
                const SizedBox(height: 24),
                _ManualLinkPanel(
                  controller: _manualController,
                  onPaste: _paste,
                  onSubmit: () => widget.onParseManual(_manualController.text),
                ),
                const SizedBox(height: 18),
                _QuickTools(onOpen: widget.onOpenTool),
                const SizedBox(height: 22),
                _RecentTasks(
                  records: widget.recentDownloads.take(4).toList(),
                  onShowAll: widget.onShowAllTasks,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualLinkPanel extends StatelessWidget {
  const _ManualLinkPanel({
    required this.controller,
    required this.onPaste,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback onPaste;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return LangbaiCard(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final form = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '粘贴链接开始',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 7),
                Text(
                  '支持网页媒体、音视频直链和公开图片',
                  style: TextStyle(color: context.palette.textMuted),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: controller,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => onSubmit(),
                  decoration: InputDecoration(
                    hintText: 'https://…',
                    prefixIcon: const Icon(Icons.link_rounded),
                    suffixIcon: IconButton(
                      tooltip: '粘贴',
                      onPressed: onPaste,
                      icon: const Icon(Icons.content_paste_rounded),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: onSubmit,
                  icon: const Icon(Icons.auto_awesome_rounded),
                  label: const Text('识别链接'),
                ),
              ],
            );
            if (compact) return form;
            return Row(
              children: [
                Expanded(flex: 7, child: form),
                const SizedBox(width: 28),
                Expanded(
                  flex: 3,
                  child: Image.asset(
                    'assets/images/langbai_mascot.png',
                    height: 280,
                    fit: BoxFit.contain,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _QuickTools extends StatelessWidget {
  const _QuickTools({required this.onOpen});

  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    const tools = [
      ('parser', Icons.play_circle_outline_rounded, '视频解析', '分辨率 / 音频 / 封面'),
      ('audio', Icons.graphic_eq_rounded, '音频提取', '从视频导出音频'),
      ('compress', Icons.compress_rounded, '媒体压缩', '视频与图片缩小体积'),
      ('music', Icons.headphones_rounded, '多源音乐搜索', '开放下载 / 试听 / 全球元数据'),
      ('transfer', Icons.hub_outlined, '高级下载', '直链 / 磁力 / 种子'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 5
            : constraints.maxWidth >= 560
            ? 3
            : 1;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final tool in tools)
              SizedBox(
                width: width,
                child: LangbaiCard(
                  child: InkWell(
                    onTap: () => onOpen(tool.$1),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: Row(
                        children: [
                          Icon(
                            tool.$2,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  tool.$3,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  tool.$4,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: context.palette.textMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _RecentTasks extends StatelessWidget {
  const _RecentTasks({required this.records, required this.onShowAll});

  final List<DownloadRecord> records;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    return LangbaiCard(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 13, 10, 10),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '最近任务',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton(onPressed: onShowAll, child: const Text('全部任务')),
              ],
            ),
          ),
          Divider(height: 1, color: context.palette.border),
          if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.all(26),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 10,
                runSpacing: 6,
                children: [
                  Icon(
                    Icons.download_done_rounded,
                    color: context.palette.textMuted,
                  ),
                  Text(
                    '还没有下载任务',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.palette.textMuted),
                  ),
                ],
              ),
            )
          else
            for (var index = 0; index < records.length; index++) ...[
              _TaskRow(record: records[index]),
              if (index != records.length - 1)
                Divider(height: 1, color: context.palette.border),
            ],
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.record});

  final DownloadRecord record;

  @override
  Widget build(BuildContext context) {
    final job = record.job;
    final completed = job.state == JobState.completed;
    final metrics = _dashboardTransferSummary(job);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final title = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(record.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              if (metrics.isNotEmpty)
                Text(
                  metrics,
                  style: TextStyle(
                    color: context.palette.textMuted,
                    fontSize: 11,
                  ),
                ),
            ],
          );
          final progress = LinearProgressIndicator(
            minHeight: 5,
            borderRadius: BorderRadius.circular(8),
            value: job.state == JobState.queued ? null : job.progress,
          );
          final icon = Icon(
            completed
                ? Icons.check_circle_outline_rounded
                : Icons.downloading_rounded,
            color: completed
                ? context.palette.success
                : Theme.of(context).colorScheme.primary,
          );
          if (constraints.maxWidth < 520) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    Expanded(child: title),
                    const SizedBox(width: 8),
                    Text('${(job.progress * 100).round()}%'),
                  ],
                ),
                const SizedBox(height: 8),
                progress,
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: 12),
              Expanded(flex: 4, child: title),
              const SizedBox(width: 12),
              Expanded(flex: 3, child: progress),
              const SizedBox(width: 12),
              SizedBox(
                width: 58,
                child: Text(
                  '${(job.progress * 100).round()}%',
                  textAlign: TextAlign.end,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

String _dashboardTransferSummary(DownloadJob job) {
  final parts = <String>[];
  if (job.downloadedBytes != null) {
    parts.add(
      job.totalBytes == null
          ? _dashboardBytes(job.downloadedBytes!)
          : '${_dashboardBytes(job.downloadedBytes!)} / ${_dashboardBytes(job.totalBytes!)}',
    );
  }
  final speed = job.speedBytesPerSecond ?? job.averageSpeedBytesPerSecond;
  if (speed != null && speed > 0) {
    parts.add('${_dashboardBytes(speed.round())}/s');
  }
  return parts.join(' · ');
}

String _dashboardBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib >= 100 ? 0 : 1)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(mib >= 100 ? 0 : 1)} MB';
  return '${(mib / 1024).toStringAsFixed(2)} GB';
}
