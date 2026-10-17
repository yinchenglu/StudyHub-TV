/// 全局常量。改版本号只改这里 + pubspec.yaml（两处必须一致，启动时会 assert）。
library;

const String kAppName = 'StudyHub TV';

/// 界面左下角「工具 → 关于」里显示的版本
const String kAppVersion = '1.1.0';

/// pubspec.yaml 里的 version（去掉 +N 后要和上面一致）
const String kPubspecVersion = '1.1.0+3';

/// 项目主页（「关于」里点一下会提示这个地址）
const String kRepoUrl = 'https://github.com/yinchenglu/StudyHub-TV';

/// 原生抽帧通道名（对应 android_custom/MainActivity.kt）
const String kThumbChannel = 'studyhubtv/thumb';

/// 支持的图片扩展名（小写，不带点）
const Set<String> kImageExts = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'avif', 'jfif',
};

/// 支持的视频扩展名
const Set<String> kVideoExts = {
  'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'ts', 'm2ts', 'mts', 'rmvb', 'rm',
  'webm', 'mpg', 'mpeg', '3gp', 'vob', 'ogv', 'divx', 'asf',
};

/// 支持的音频扩展名
const Set<String> kAudioExts = {
  'mp3', 'flac', 'wav', 'aac', 'm4a', 'ogg', 'oga', 'opus', 'wma', 'ape', 'alac',
  'dts', 'ac3', 'aiff', 'mid',
};

/// 判断文件类型用的统一后缀（字幕文件也算音频目录里的"可忽略物"）
const Set<String> kSubtitleExts = {'srt', 'ass', 'ssa', 'sub', 'vtt', 'idx'};
