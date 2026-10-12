import 'package:flutter_test/flutter_test.dart';
import 'package:lectern/engines/epub/epub_content.dart';

ParsedChapter parse(String body, {String path = 'OEBPS/text/ch1.xhtml'}) =>
    parseXhtml(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops">'
      '<head><title>Ignored title</title><style>p { color: red }</style>'
      '</head><body>$body</body></html>',
      path: path,
    );

/// The text of each block.
List<String> texts(ParsedChapter chapter) => [
  for (final b in chapter.blocks) chapter.text.substring(b.start, b.end),
];

void main() {
  test('paragraphs become blocks; whitespace collapses', () {
    final chapter = parse(
      '<p>  Hello,\n   world!  </p>\n<p>Second\tparagraph.</p>',
    );
    expect(texts(chapter), ['Hello, world!', 'Second paragraph.']);
    expect(chapter.text, 'Hello, world!\nSecond paragraph.');
    expect(chapter.blocks.map((b) => b.kind), [
      BlockKind.paragraph,
      BlockKind.paragraph,
    ]);
  });

  test('head, scripts, styles and forms are not shown', () {
    final chapter = parse(
      '<script>alert("x")</script><p>Kept</p>'
      '<form><input value="no"/><button>Press</button></form>'
      '<iframe src="x.html">frame</iframe>',
    );
    expect(chapter.text, 'Kept');
  });

  test('inline styles become runs relative to the block', () {
    final chapter = parse(
      '<p>Plain <b>bold <i>both</i></b> <code>x()</code></p>',
    );
    expect(texts(chapter).single, 'Plain bold both x()');
    expect(chapter.blocks.single.runs, const [
      StyledRun(6, 11, InlineStyle.bold),
      StyledRun(11, 15, InlineStyle.bold | InlineStyle.italic),
      StyledRun(16, 19, InlineStyle.monospace),
    ]);
  });

  test('headings, quotes, lists and captions get their kinds', () {
    final chapter = parse(
      '<h2>Title</h2>'
      '<blockquote><p>Quoted</p></blockquote>'
      '<ul><li>One</li><li>Two<ol start="3"><li>Three</li></ol></li></ul>'
      '<figure><img src="../img/a.png" width="200" height="100" alt="A"/>'
      '<figcaption>Caption</figcaption></figure>',
    );
    expect(texts(chapter), [
      'Title',
      'Quoted',
      '• One',
      '• Two',
      '3. Three',
      objectReplacement,
      'Caption',
    ]);
    final blocks = chapter.blocks;
    expect(blocks[0].kind, BlockKind.heading);
    expect(blocks[0].level, 2);
    expect(blocks[1].kind, BlockKind.quote);
    expect(blocks[2].kind, BlockKind.listItem);
    expect(blocks[2].level, 1);
    expect(blocks[4].level, 2);
    expect(blocks[5].kind, BlockKind.image);
    expect(blocks[5].imagePath, 'OEBPS/img/a.png');
    expect(blocks[5].imageAlt, 'A');
    expect(blocks[5].aspectRatio, 2);
    expect(blocks[6].kind, BlockKind.caption);
    expect(blocks[6].centered, isTrue);
  });

  test('preformatted text keeps its spacing and line breaks', () {
    final chapter = parse('<pre>a  b\r\n  c</pre><p>x <br/>y</p>');
    expect(texts(chapter), ['a  b\n  c', 'x \ny']);
    expect(chapter.blocks.first.kind, BlockKind.preformatted);
  });

  test('ids become anchors at the right offsets', () {
    final chapter = parse(
      '<p id="first">One</p>'
      '<h2 id="second">Two</h2>'
      '<p>Three <span id="inline">four</span></p>',
    );
    expect(chapter.anchors['first'], 0);
    expect(chapter.anchors['second'], chapter.text.indexOf('Two'));
    expect(chapter.anchors['inline'], chapter.text.indexOf('four'));
  });

  test('links resolve within the book or to web addresses', () {
    final chapter = parse(
      '<p><a href="#note1">1</a> '
      '<a href="ch2.xhtml#part%202">next</a> '
      '<a href="https://example.com/x">web</a> '
      '<a href="javascript:alert(1)">bad</a> '
      '<a href="../../../../etc/passwd">escape</a></p>',
    );
    expect(chapter.links, [
      const ContentLink.internal('OEBPS/text/ch1.xhtml', 'note1'),
      const ContentLink.internal('OEBPS/text/ch2.xhtml', 'part 2'),
      ContentLink.external(Uri.parse('https://example.com/x')),
    ]);
    final runs = chapter.blocks.single.runs;
    expect(runs.map((r) => r.link), [0, 1, 2]);
  });

  test('svg-wrapped cover images are kept; other svg content is not', () {
    final chapter = parse(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'xmlns:xlink="http://www.w3.org/1999/xlink">'
      '<g><image xlink:href="../images/cover.jpg" width="600" height="800"/>'
      '</g><text>Not shown</text></svg>',
    );
    expect(chapter.blocks.single.kind, BlockKind.image);
    expect(chapter.blocks.single.imagePath, 'OEBPS/images/cover.jpg');
    expect(chapter.blocks.single.aspectRatio, 0.75);
  });

  test('tolerates sloppy markup and keeps text before a fatal error', () {
    final chapter = parse(
      '<p>Open <b>bold</p><p>&nbsp;&mdash;dash &unknown;</p>'
      '<p>Stray </i>end</p>',
    );
    expect(chapter.text, contains('Open bold'));
    expect(chapter.text, contains(' —dash'));

    final broken = parseXhtml(
      '<html><body><p>Before</p><p>After <',
      path: 'a.xhtml',
    );
    expect(broken.text, startsWith('Before'));
  });

  test('long paragraphs are split at spaces into continuing blocks', () {
    final words = List.generate(1000, (i) => 'word$i').join(' ');
    final chapter = parse('<p>$words</p><p>End</p>');
    final blocks = chapter.blocks;
    expect(blocks.length, greaterThan(3));
    for (final block in blocks.take(blocks.length - 2)) {
      expect(block.length, lessThanOrEqualTo(2000));
      expect(block.continues, isTrue);
    }
    expect(blocks[blocks.length - 2].continues, isFalse);
    // Splitting never loses or reorders text.
    expect(texts(chapter).take(blocks.length - 1).join(), words);
  });

  test('stops at the size limit', () {
    final chapter = parseXhtml(
      '<html><body>${'<p>${'x' * 100}</p>' * 100}</body></html>',
      path: 'a.xhtml',
      maxChars: 1000,
    );
    expect(chapter.truncated, isTrue);
    expect(chapter.text.length, lessThan(1300));
  });

  test('hostile nesting stays fast', () {
    final stopwatch = Stopwatch()..start();
    final chapter = parseXhtml(
      '<html><body>${'<span>' * 5000}'
      '${'<p>text</p>' * 20000}${'</span>' * 5000}</body></html>',
      path: 'a.xhtml',
    );
    expect(chapter.blocks, hasLength(20000));
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test('deeply nested markup does not overflow the stack', () {
    final chapter = parseXhtml(
      '<html><body>${'<div>' * 20000}<p>Deep</p>${'</div>' * 20000}'
      '</body></html>',
      path: 'a.xhtml',
    );
    expect(chapter.text, 'Deep');
  });
}
