import 'constants.dart';

/// 字节数转人话：1.2 GB / 340 MB / 12 KB
String fmtBytes(int bytes) {
  if (bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(v >= 10 ? 0 : 1);
  return '$s ${units[i]}';
}

/// 时间转人话：2024-05-03 12:08
String fmtTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// 时长（毫秒）转 1:23 / 1:02:03
String fmtDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60);
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// 取小写扩展名（不带点）
String extOf(String name) {
  final i = name.lastIndexOf('.');
  if (i <= 0 || i == name.length - 1) return '';
  return name.substring(i + 1).toLowerCase();
}

/// 文件名去掉扩展名，给「显示标题」用
String stemOf(String name) {
  final i = name.lastIndexOf('.');
  return i <= 0 ? name : name.substring(0, i);
}

/// 自然排序：让「第2集」排在「第10集」前面。
///
/// 服务器返回的顺序五花八门（群晖按 UTF-8 字节序、Windows 按大小写不敏感），
/// 电视上看片最难受的就是「1、10、11、2」。这里自己按「数字段当数值比」排。
int naturalCompare(String a, String b) {
  final ae = extOf(a);
  final be = extOf(b);
  // 同目录下先按类型分（图片/视频同名不同后缀的情况很少，但排序稳定些）
  if (ae != be) return ae.compareTo(be);
  final al = a.toLowerCase();
  final bl = b.toLowerCase();
  var i = 0, j = 0;
  while (i < al.length && j < bl.length) {
    final ca = al.codeUnitAt(i);
    final cb = bl.codeUnitAt(j);
    final da = ca >= 48 && ca <= 57;
    final db = cb >= 48 && cb <= 57;
    if (da && db) {
      var si = i, sj = j;
      while (si < al.length && (al.codeUnitAt(si) >= 48 && al.codeUnitAt(si) <= 57)) {
        si++;
      }
      while (sj < bl.length && (bl.codeUnitAt(sj) >= 48 && bl.codeUnitAt(sj) <= 57)) {
        sj++;
      }
      final na = int.tryParse(al.substring(i, si)) ?? 0;
      final nb = int.tryParse(bl.substring(j, sj)) ?? 0;
      if (na != nb) return na.compareTo(nb);
      i = si;
      j = sj;
      continue;
    }
    if (ca != cb) return ca.compareTo(cb);
    i++;
    j++;
  }
  return al.length.compareTo(bl.length);
}

/// 整数夹取。不用 num.clamp 是因为它返回的是 num，
/// 拿去做 List 下标或 int 变量会报类型错。
int clampInt(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

/// 浮点夹取。同样的道理：num.clamp 返回 num，赋给 double 变量会报类型错。
double clampDouble(double v, double lo, double hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// 解码失败时给的替代文字（服务器常返回乱七八糟编码的目录名）
String safeName(String s) => s.isEmpty ? '(未命名)' : s;
