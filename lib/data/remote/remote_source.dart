import 'dart:io' show File;

import '../models.dart';
import 'smb_source.dart';
import 'webdav_source.dart';

/// 连接失败 / 服务器报错时抛这个，message 是给人看的中文
class RemoteException implements Exception {
  final String message;
  RemoteException(this.message);
  @override
  String toString() => message;
}

/// 远程文件源。WebDAV 和 SMB 都实现这一套接口，
/// 上层界面完全不用关心底下是哪种协议。
abstract class RemoteSource {
  Account get account;

  /// 列出某个相对目录下的内容（只列一层）
  Future<List<RemoteEntry>> list(String rel);

  /// 连通性自检，返回一句人话结论（"连接正常，共 12 项"）
  Future<String> check();

  /// 拿到播放器 / 图片组件能直接用的地址（纯字符串拼接，同步返回）
  MediaRef ref(String rel);

  /// 把一个本地文件传到远端（[rel] 是相对账号根目录的路径，含文件名）。
  ///
  /// v1.5 新增，只有 WebDAV 实现了 PUT；SMB 那边 smb_connect 的写支持
  /// 不完整，所以默认实现直接抛"不支持"，界面据此提示用户换 WebDAV。
  Future<void> put(String rel, File local) {
    throw RemoteException('${account.proto.label} 暂不支持上传，请改用 WebDAV 账号');
  }

  Future<void> dispose();

  /// 按协议创建对应的实现
  static Future<RemoteSource> open(Account account) async {
    if (account.proto == Proto.smb) {
      final s = SmbSource(account);
      await s.connect();
      return s;
    }
    return WebDavSource(account);
  }
}
