import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/fmt.dart';

/// 连接协议
enum Proto {
  webdav,
  smb;

  String get label => this == Proto.webdav ? 'WebDAV' : 'SMB';

  /// 地址输入框的提示文字（两种协议填的东西不一样，提示必须分开）
  String get addrHint =>
      this == Proto.webdav ? 'http://192.168.1.10:5005' : '192.168.1.10';

  String get rootHint =>
      this == Proto.webdav ? '/dav' : '/media';
}

/// 一个服务器账号。
///
/// 密码不进 toJson：单独用系统加密存储保存（见 data/store.dart），
/// 这样导出的配置文件不会泄漏密码。
class Account {
  final String id;
  final String name;
  final Proto proto;

  /// WebDAV 填完整地址（含 http:// 和端口）；SMB 填主机名或 IP
  final String addr;

  /// SMB 端口，默认 445
  final int port;
  final String user;
  final String password;

  /// WebDAV：地址后面的路径前缀，例如 /dav 或 /remote.php/dav/files/me
  /// SMB：共享名 + 子目录，例如 /media 或 /video/电影
  final String root;

  /// SMB 域（Windows 域账号才要，群晖/威联通留空）
  final String domain;

  const Account({
    required this.id,
    required this.name,
    required this.proto,
    required this.addr,
    this.port = 445,
    this.user = '',
    this.password = '',
    this.root = '',
    this.domain = '',
  });

  Account copyWith({
    String? name,
    Proto? proto,
    String? addr,
    int? port,
    String? user,
    String? password,
    String? root,
    String? domain,
  }) =>
      Account(
        id: id,
        name: name ?? this.name,
        proto: proto ?? this.proto,
        addr: addr ?? this.addr,
        port: port ?? this.port,
        user: user ?? this.user,
        password: password ?? this.password,
        root: root ?? this.root,
        domain: domain ?? this.domain,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'proto': proto.name,
        'addr': addr,
        'port': port,
        'user': user,
        'root': root,
        'domain': domain,
      };

  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
        name: j['name'] as String? ?? '我的服务器',
        proto: (j['proto'] as String?) == 'smb' ? Proto.smb : Proto.webdav,
        addr: j['addr'] as String? ?? '',
        port: (j['port'] as num?)?.toInt() ?? 445,
        user: j['user'] as String? ?? '',
        root: j['root'] as String? ?? '',
        domain: j['domain'] as String? ?? '',
      );

  /// 一句话摘要，账户列表里显示
  String get summary {
    final a = proto == Proto.smb ? '${addr.isEmpty ? '?' : addr}:$port' : addr;
    final r = root.isEmpty ? '' : root;
    return '$a$r';
  }
}

/// 服务器上的一个条目（文件或目录）
class RemoteEntry {
  final String path; // 相对「账号根目录」的路径，例如 电影/流浪地球.mkv
  final bool isDir;
  final int size;
  final DateTime? modified;

  const RemoteEntry({
    required this.path,
    required this.isDir,
    this.size = 0,
    this.modified,
  });

  String get name {
    final p = path.replaceAll(RegExp(r'/+$'), '');
    final i = p.lastIndexOf('/');
    return i < 0 ? p : p.substring(i + 1);
  }

  String get ext => isDir ? '' : extOf(name);

  /// 这个条目属于哪一类
  MediaKind get kind {
    if (isDir) return MediaKind.folder;
    final e = ext;
    if (kImageExts.contains(e)) return MediaKind.image;
    if (kVideoExts.contains(e)) return MediaKind.video;
    if (kAudioExts.contains(e)) return MediaKind.audio;
    return MediaKind.other;
  }
}

enum MediaKind { folder, image, video, audio, other }

/// 左侧菜单的六个入口。声明顺序 = 菜单显示顺序（v1.2 起「账户」在最上面）。
enum Section {
  accounts,
  images,
  videos,
  audio,
  tools,
  settings;

  bool get isMedia =>
      this == Section.images || this == Section.videos || this == Section.audio;

  /// 这一项前面要不要画一条分割线（视觉上把「媒体」和「系统」分组）
  bool get dividerBefore => this == Section.tools;

  String get label {
    switch (this) {
      case Section.images:
        return '图片';
      case Section.videos:
        return '视频';
      case Section.audio:
        return '音频';
      case Section.accounts:
        return '账户';
      case Section.settings:
        return '设置';
      case Section.tools:
        return '工具';
    }
  }

  IconData get icon {
    switch (this) {
      case Section.images:
        return Icons.photo_library_outlined;
      case Section.videos:
        return Icons.movie_outlined;
      case Section.audio:
        return Icons.library_music_outlined;
      case Section.accounts:
        return Icons.person_outline;
      case Section.settings:
        return Icons.settings_outlined;
      case Section.tools:
        return Icons.handyman_outlined;
    }
  }

  /// 这个分区只收哪一类文件
  MediaKind? get accept {
    switch (this) {
      case Section.images:
        return MediaKind.image;
      case Section.videos:
        return MediaKind.video;
      case Section.audio:
        return MediaKind.audio;
      default:
        return null;
    }
  }

  /// 空目录时给的提示
  String get emptyHint {
    switch (this) {
      case Section.images:
        return '这个目录里没有图片';
      case Section.videos:
        return '这个目录里没有视频';
      case Section.audio:
        return '这个目录里没有音乐';
      default:
        return '这里是空的';
    }
  }
}

/// 播放模式（播放器里可切换，选择会记住）
enum PlayMode {
  /// 顺序播完整个目录，最后一个播完就停
  order,

  /// 单集循环：一直重复当前
  repeatOne,

  /// 随机播放
  shuffle,

  /// 目录循环：播完最后一个自动回到第一个
  loopDir;

  String get label {
    switch (this) {
      case PlayMode.order:
        return '顺序播放';
      case PlayMode.repeatOne:
        return '单个循环';
      case PlayMode.shuffle:
        return '随机播放';
      case PlayMode.loopDir:
        return '目录循环';
    }
  }

  IconData get icon {
    switch (this) {
      case PlayMode.order:
        return Icons.playlist_play_rounded;
      case PlayMode.repeatOne:
        return Icons.repeat_one_rounded;
      case PlayMode.shuffle:
        return Icons.shuffle_rounded;
      case PlayMode.loopDir:
        return Icons.repeat_rounded;
    }
  }

  PlayMode get next => PlayMode.values[(index + 1) % PlayMode.values.length];
  PlayMode get prev =>
      PlayMode.values[(index - 1 + PlayMode.values.length) % PlayMode.values.length];

  static PlayMode fromIndex(int i) =>
      (i >= 0 && i < PlayMode.values.length) ? PlayMode.values[i] : PlayMode.order;
}

/// 播放/显示一个远程文件需要的信息
class MediaRef {
  /// 播放器或图片组件直接用的完整地址
  final String url;

  /// 需要带的请求头（WebDAV 的 Basic Auth；SMB 走本地桥，为空）
  final Map<String, String> headers;

  const MediaRef(this.url, [this.headers = const {}]);
}
