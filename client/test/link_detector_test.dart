import 'package:flutter_test/flutter_test.dart';
import 'package:media_harbor/services/link_detector.dart';

const douyinShareText = '3.05 复制打开抖音，看看【樱梨梨的作品】他们走不了了 '
    '# 瓦是大明星 # 瓦赛来了 # 暮... '
    'https://v.douyin.com/9AgsTehs2gM/ C@H.Vl :1pm 10/02 Agb:/';

void main() {
  test('extracts the URL from a complete Douyin share message', () {
    expect(
      LinkDetector.extractHttpUrl(douyinShareText),
      'https://v.douyin.com/9AgsTehs2gM/',
    );

    final detected = LinkDetector().detect(douyinShareText);
    expect(detected?.kind, DetectedLinkKind.web);
    expect(detected?.value, 'https://v.douyin.com/9AgsTehs2gM/');
  });

  test('removes punctuation appended to a shared URL', () {
    expect(
      LinkDetector.extractHttpUrl('看看 https://example.com/video，'),
      'https://example.com/video',
    );
  });
}
