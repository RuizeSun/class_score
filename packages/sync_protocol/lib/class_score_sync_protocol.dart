/// App 与服务端共用的同步协议。
///
/// 这里只放**纯 Dart**：不依赖 Flutter、不依赖 sqlite 绑定，因此同一份代码
/// 既能被 Windows 客户端引用，也能被 `server/` 里的 shelf 服务端引用。
library;

export 'src/event.dart';
export 'src/lww.dart';
export 'src/protocol.dart';
