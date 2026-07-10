import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/download_record.dart';
import '../models/media_models.dart';
import '../services/link_detector.dart';
import '../theme/langbai_theme.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    super.key,
    required this.detectedLink,
    required this.clipboardDetectionEnabled,
    required this.recentDownloads,
    required this.onParseDetected,
    required this.onIgnoreDetected,
    required this.onClipboardDetectionChanged,
    required this.onCheckClipboard,
    required this.onParseManual,
    required this.onOpenTool,
    required this.onShowAllTasks,
  });

  final DetectedLink? detectedLink;
  final bool clipboardDetectionEnabled;
  final List<DownloadRecord> recentDownloads;
  final ValueChanged<DetectedLink> onParseDetected;
  final VoidCallback onIgnoreDetected;
  final ValueChanged<bool> onClipboardDetectionChanged;
  final VoidCallback onCheckClipboard;
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
                  '晚上好，欢迎使用 langbai解析',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -.4,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.detectedLink == null
                      ? '粘贴链接开始解析，或从工具箱选择其他任务'
                      : '检测到剪贴板中有可处理的链接',
                  style: TextStyle(color: context.palette.textMuted),
                ),
                const SizedBox(height: 24),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: widget.detectedLink == null
                      ? _ManualLinkPanel(
                          key: const ValueKey('manual'),
                          controller: _manualController,
                          onPaste: _paste,
                          onSubmit: () =>
                              widget.onParseManual(_manualController.text),
                          onCheckClipboard: widget.onCheckClipboard,
                          clipboardDetectionEnabled:
                              widget.clipboardDetectionEnabled,
                          onClipboardDetectionChanged:
                              widget.onClipboardDetectionChanged,
                        )
                      : _DetectedLinkPanel(
                          key: ValueKey(widget.detectedLink!.value),
                          link: widget.detectedLink!,
                          clipboardDetectionEnabled:
                              widget.clipboardDetectionEnabled,
                          onClipboardDetectionChanged:
                              widget.onClipboardDetectionChanged,
                          onParse: () =>
                              widget.onParseDetected(widget.detectedLink!),
                          onIgnore: widget.onIgnoreDetected,
                        ),
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

class _DetectedLinkPanel extends StatelessWidget {
  const _DetectedLinkPanel({
    super.key,
    required this.link,
    required this.clipboardDetectionEnabled,
    required this.onClipboardDetectionChanged,
    required this.onParse,
    required this.onIgnore,
  });

  final DetectedLink link;
  final bool clipboardDetectionEnabled;
  final ValueChanged<bool> onClipboardDetectionChanged;
  final VoidCallback onParse;
  final VoidCallback onIgnore;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(link.value);
    final source = uri?.host.replaceFirst('www.', '') ?? '已识别链接';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 740;
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('检测到${link.label}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(source.characters.first.toUpperCase(),
                          style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w800,
                              color: Theme.of(context).colorScheme.primary)),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(source,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text(link.label,
                              style: TextStyle(
                                  color: context.palette.textMuted,
                                  fontSize: 13)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),
                Container(
                  height: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 15),
                  decoration: BoxDecoration(
                    color: context.palette.surfaceRaised,
                    border: Border.all(color: context.palette.border),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.link_rounded, size: 20),
                      const SizedBox(width: 11),
                      Expanded(
                          child: Text(link.value,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  TextStyle(color: context.palette.textMuted))),
                      IconButton(
                        tooltip: '复制链接',
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: link.value)),
                        icon: const Icon(Icons.copy_rounded, size: 19),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    Checkbox(
                        value: clipboardDetectionEnabled,
                        onChanged: (value) =>
                            onClipboardDetectionChanged(value ?? true)),
                    Expanded(
                      child: Text('以后检测到链接时提醒我',
                          style: TextStyle(
                              color: context.palette.textMuted, fontSize: 13)),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (compact)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      FilledButton.icon(
                          onPressed: onParse,
                          icon: const Icon(Icons.auto_awesome_rounded),
                          label: const Text('立即解析')),
                      const SizedBox(height: 9),
                      OutlinedButton(
                          onPressed: onIgnore, child: const Text('忽略')),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      SizedBox(
                          width: 150,
                          child: OutlinedButton(
                              onPressed: onIgnore, child: const Text('忽略'))),
                      const SizedBox(width: 10),
                      SizedBox(
                          width: 190,
                          child: FilledButton.icon(
                              onPressed: onParse,
                              icon: const Icon(Icons.auto_awesome_rounded),
                              label: const Text('立即解析'))),
                    ],
                  ),
              ],
            );
            if (compact) return content;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(flex: 7, child: content),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: Semantics(
                    image: true,
                    label: 'langbai 产品形象正在挥手',
                    child: Image.asset('assets/images/langbai_mascot.png',
                        height: 300, fit: BoxFit.contain),
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

class _ManualLinkPanel extends StatelessWidget {
  const _ManualLinkPanel({
    super.key,
    required this.controller,
    required this.onPaste,
    required this.onSubmit,
    required this.onCheckClipboard,
    required this.clipboardDetectionEnabled,
    required this.onClipboardDetectionChanged,
  });

  final TextEditingController controller;
  final VoidCallback onPaste;
  final VoidCallback onSubmit;
  final VoidCallback onCheckClipboard;
  final bool clipboardDetectionEnabled;
  final ValueChanged<bool> onClipboardDetectionChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final form = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('粘贴链接开始',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 7),
                Text('支持网页媒体、音视频直链和公开图片',
                    style: TextStyle(color: context.palette.textMuted)),
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
                        icon: const Icon(Icons.content_paste_rounded)),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                    onPressed: onSubmit,
                    icon: const Icon(Icons.auto_awesome_rounded),
                    label: const Text('识别链接')),
                const SizedBox(height: 8),
                TextButton.icon(
                    onPressed: onCheckClipboard,
                    icon: const Icon(Icons.content_paste_search_rounded),
                    label: const Text('检查剪贴板')),
                const SizedBox(height: 8),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: clipboardDetectionEnabled,
                  onChanged: onClipboardDetectionChanged,
                  title: const Text('进入应用时识别剪贴板链接',
                      style: TextStyle(fontSize: 14)),
                  subtitle:
                      const Text('只识别，解析前始终询问', style: TextStyle(fontSize: 12)),
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
                  child: Image.asset('assets/images/langbai_mascot.png',
                      height: 280, fit: BoxFit.contain),
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
      ('music', Icons.headphones_rounded, '音乐搜索', '合法来源无损资源'),
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
                child: Card(
                  child: InkWell(
                    onTap: () => onOpen(tool.$1),
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.all(15),
                      child: Row(
                        children: [
                          Icon(tool.$2,
                              color: Theme.of(context).colorScheme.primary),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(tool.$3,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700)),
                                const SizedBox(height: 3),
                                Text(tool.$4,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: context.palette.textMuted,
                                        fontSize: 11)),
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
    return Card(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 13, 10, 10),
            child: Row(
              children: [
                const Expanded(
                    child: Text('最近任务',
                        style: TextStyle(fontWeight: FontWeight.w800))),
                TextButton(onPressed: onShowAll, child: const Text('全部任务')),
              ],
            ),
          ),
          Divider(height: 1, color: context.palette.border),
          if (records.isEmpty)
            Padding(
              padding: const EdgeInsets.all(26),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.download_done_rounded,
                      color: context.palette.textMuted),
                  const SizedBox(width: 10),
                  Text('还没有下载任务',
                      style: TextStyle(color: context.palette.textMuted)),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      child: Row(
        children: [
          Icon(
              completed
                  ? Icons.check_circle_outline_rounded
                  : Icons.downloading_rounded,
              color: completed
                  ? context.palette.success
                  : Theme.of(context).colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
              flex: 4,
              child: Text(record.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: LinearProgressIndicator(
              minHeight: 5,
              borderRadius: BorderRadius.circular(8),
              value: job.state == JobState.queued ? null : job.progress,
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
              width: 58,
              child: Text('${(job.progress * 100).round()}%',
                  textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}
