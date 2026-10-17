import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart' show HASH_COMMENT_MODE, Mode;

final Mode editorYamlMode = Mode(
  refs: {
    ...?langYaml.refs,
    '~contains~14': Mode(
      className: 'number',
      begin:
          r'(-?)(\b0[xX][a-fA-F0-9]+|(\b\d+(\.\d*)?|\.\d+)([eE][-+]?\d+)?)\b(?=[\s,\]}]|$)',
      relevance: 0,
    ),
  },
  name: langYaml.name,
  caseInsensitive: langYaml.caseInsensitive,
  contains: [
    for (final mode in langYaml.contains ?? const <Mode>[])
      identical(mode, HASH_COMMENT_MODE)
          ? Mode(scope: 'comment', begin: r'(?<![^\s])#', end: r'$')
          : mode,
  ],
);

/// JavaScript 语法高亮模式，从内置的 [langJavascript] 派生，
/// 与 [editorYamlMode] 采用同样的改写方式，作为脚本预览的项目级定制入口。
final Mode editorJsMode = Mode(
  refs: {
    ...?langJavascript.refs,
  },
  name: langJavascript.name,
  caseInsensitive: langJavascript.caseInsensitive,
  keywords: langJavascript.keywords,
  contains: [
    for (final mode in langJavascript.contains ?? const <Mode>[]) mode,
  ],
);
