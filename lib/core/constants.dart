/// 全局常量。改版本号只改这里 + pubspec.yaml（两处必须一致，启动时会 assert）。
library;

const String kAppName = 'StudyHub TV';

/// 界面左下角「工具 → 关于」里显示的版本
const String kAppVersion = '1.2.0';

/// pubspec.yaml 里的 version（去掉 +N 后要和上面一致）
const String kPubspecVersion = '1.2.0+2004';

/// 项目主页（「关于」里点一下会提示这个地址）
const String kRepoUrl = 'https://github.com/yinchenglu/StudyHub-TV';

/// 原生抽帧通道名（对应 android_custom/MainActivity.kt）
const String kThumbChannel = 'studyhubtv/thumb';

/// ---------------------------------------------------------------
/// 媒体库目录约定（v1.2 起自动识别，不需要用户手填）
///
///   <账号根目录>/StudyHub-TV/image   ← 图片
///   <账号根目录>/StudyHub-TV/video   ← 视频
///   <账号根目录>/StudyHub-TV/audio   ← 音频
///   <账号根目录>/StudyHub-TV/download ← 工具里的「下载工作」
///
/// 下面这些集合是"同一个意思的不同写法"：用户可能把文件夹建成
/// images / photo / 图片…… 全都认，免得因为少个 s 就看不见东西。
/// 匹配一律按小写比较。
/// ---------------------------------------------------------------

/// 媒体库根目录的候选名（大小写不敏感）
const Set<String> kLibraryDirNames = {
  'studyhub-tv', 'studyhub_tv', 'studyhubtv', 'studyhub tv',
};

const Set<String> kImageDirNames = {
  'image', 'images', 'img', 'imgs', 'photo', 'photos', 'picture', 'pictures',
  '图片', '照片', '相册',
};

const Set<String> kVideoDirNames = {
  'video', 'videos', 'movie', 'movies', 'film', 'films', '视频', '影片', '电影',
};

const Set<String> kAudioDirNames = {
  'audio', 'audios', 'music', 'musics', 'sound', 'sounds', '音频', '音乐', '歌曲',
};

const Set<String> kDownloadDirNames = {
  'download', 'downloads', '下载',
};

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

/// 手机扫码填写账号的本地服务端口（0 = 让系统随机分配）
const int kPairPort = 0;
