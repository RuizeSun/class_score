import 'dart:io';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../../models/student.dart';
import 'ai_roster_process_page.dart';

/// 花名册取景 / 选图 / 裁剪页。
///
/// 入口：评分页「AI 选学生」按钮 → push 本页。
/// 出口：裁剪完成后 push [AiRosterProcessPage]，采用后把学生 id 集合
/// 原样 pop 回评分页。
class AiRosterCapturePage extends StatefulWidget {
  const AiRosterCapturePage({super.key, required this.candidates});

  /// 候选学生（评分页当前筛选范围内的学生）。
  final List<Student> candidates;

  @override
  State<AiRosterCapturePage> createState() => _AiRosterCapturePageState();
}

enum _Source { camera, image }

class _AiRosterCapturePageState extends State<AiRosterCapturePage> {
  _Source _source = _Source.camera;

  List<CameraDescription> _cameras = const [];
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _cameraLoading = true;
  String? _cameraError;

  Uint8List? _sourceBytes;
  Rect _cropRect = const Rect.fromLTRB(0.06, 0.10, 0.94, 0.90);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _initCameras();
  }

  Future<void> _initCameras() async {
    setState(() {
      _cameraLoading = true;
      _cameraError = null;
    });
    try {
      final cams = await availableCameras();
      if (!mounted) return;
      if (cams.isEmpty) {
        setState(() {
          _cameraLoading = false;
          _cameraError = '未检测到可用摄像头，可改用「选择图片」';
        });
        return;
      }
      _cameras = cams;
      if (_cameraIndex >= cams.length) _cameraIndex = 0;
      await _startCamera(_cameraIndex);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cameraLoading = false;
        _cameraError = '摄像头初始化失败：$e';
      });
    }
  }

  Future<void> _startCamera(int index) async {
    final old = _controller;
    _controller = null;
    if (mounted) {
      setState(() {
        _cameraLoading = true;
        _cameraError = null;
      });
    }
    await old?.dispose();
    final cam = _cameras[index];
    final controller = CameraController(
      cam,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _cameraIndex = index;
        _cameraLoading = false;
      });
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      setState(() {
        _cameraLoading = false;
        _cameraError = '无法打开摄像头：$e\n可改用「选择图片」';
      });
    }
  }

  Future<void> _capture() async {
    final ctrl = _controller;
    if (ctrl == null || !ctrl.value.isInitialized || _busy) return;
    setState(() => _busy = true);
    try {
      final shot = await ctrl.takePicture();
      final bytes = await shot.readAsBytes();
      if (!mounted) return;
      setState(() {
        _sourceBytes = bytes;
        _cropRect = const Rect.fromLTRB(0.06, 0.10, 0.94, 0.90);
      });
    } catch (e) {
      if (!mounted) return;
      _showMsg('拍照失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        bytes = await File(file.path!).readAsBytes();
      }
      if (bytes == null || bytes.isEmpty) {
        _showMsg('无法读取所选图片');
        return;
      }
      if (!mounted) return;
      setState(() {
        _sourceBytes = bytes;
        _cropRect = const Rect.fromLTRB(0.06, 0.10, 0.94, 0.90);
      });
    } catch (e) {
      _showMsg('选择图片失败：$e');
    }
  }

  Future<void> _confirmCrop() async {
    final src = _sourceBytes;
    if (src == null || _busy) return;
    setState(() => _busy = true);
    try {
      final size = await compute(_decodeImageSize, src);
      if (!mounted) return;
      if (size == null) {
        _showMsg('图片解析失败，请换一张图片');
        return;
      }
      final x = (_cropRect.left * size.width).round().clamp(0, size.width.toInt() - 1);
      final y = (_cropRect.top * size.height).round().clamp(0, size.height.toInt() - 1);
      final w = (_cropRect.width * size.width)
          .round()
          .clamp(1, size.width.toInt() - x);
      final h = (_cropRect.height * size.height)
          .round()
          .clamp(1, size.height.toInt() - y);
      final cropped = await compute(
        _cropAndCompress,
        _CropRequest(src, x, y, w, h),
      );
      if (!mounted) return;
      final result = await Navigator.push<Set<int>>(
        context,
        MaterialPageRoute(
          builder: (_) => AiRosterProcessPage(
            imageBytes: cropped,
            candidates: widget.candidates,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null) {
        Navigator.pop(context, result);
      }
    } catch (e) {
      if (!mounted) return;
      _showMsg('裁剪失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMsg(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showingCrop = _sourceBytes != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(showingCrop ? '裁剪花名册区域' : '拍摄或选择花名册'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (showingCrop) {
              setState(() => _sourceBytes = null);
            } else {
              Navigator.pop(context);
            }
          },
        ),
      ),
      body: showingCrop ? _buildCropBody() : _buildSourceBody(),
    );
  }

  Widget _buildSourceBody() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: SegmentedButton<_Source>(
            segments: const [
              ButtonSegment(
                value: _Source.camera,
                icon: Icon(Icons.photo_camera_outlined),
                label: Text('摄像头'),
              ),
              ButtonSegment(
                value: _Source.image,
                icon: Icon(Icons.image_outlined),
                label: Text('选择图片'),
              ),
            ],
            selected: {_source},
            onSelectionChanged: (v) {
              if (v.isEmpty) return;
              setState(() => _source = v.first);
            },
          ),
        ),
        Expanded(
          child: _source == _Source.camera ? _buildCameraPane() : _buildImagePane(),
        ),
      ],
    );
  }

  Widget _buildCameraPane() {
    if (_cameraError != null) return _buildErrorPane(_cameraError!);
    final ctrl = _controller;
    if (_cameraLoading || ctrl == null || !ctrl.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: Container(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: ctrl.value.aspectRatio,
                child: CameraPreview(ctrl),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 48,
                child: _cameras.length > 1
                    ? IconButton(
                        tooltip: '切换摄像头',
                        icon: const Icon(Icons.cameraswitch_outlined),
                        onPressed: () =>
                            _startCamera((_cameraIndex + 1) % _cameras.length),
                      )
                    : null,
              ),
              const SizedBox(width: 16),
              SizedBox(
                width: 72,
                height: 72,
                child: ElevatedButton(
                  onPressed: _busy ? null : _capture,
                  style: ElevatedButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt, size: 28),
                ),
              ),
              const SizedBox(width: 16),
              const SizedBox(width: 48),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImagePane() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.image_outlined, size: 72, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          const Text('选择已拍好的花名册照片'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.folder_open),
            label: const Text('选择图片'),
          ),
          const SizedBox(height: 8),
          Text(
            '支持 JPG / PNG / WEBP',
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorPane(String msg) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off_outlined, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(msg, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _initCameras,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
                FilledButton.icon(
                  onPressed: () => setState(() => _source = _Source.image),
                  icon: const Icon(Icons.folder_open),
                  label: const Text('改用图片'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCropBody() {
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: _CropSurface(
              imageBytes: _sourceBytes!,
              rect: _cropRect,
              onRectChanged: (r) => setState(() => _cropRect = r),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _sourceBytes = null;
                          _cropRect = const Rect.fromLTRB(0.06, 0.10, 0.94, 0.90);
                        }),
                  child: const Text('重新拍摄/选择'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy ? null : _confirmCrop,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.crop),
                  label: const Text('确认裁剪'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 裁剪显示区域：图片按 BoxFit.contain 铺开，叠加可拖动的裁剪框。
class _CropSurface extends StatefulWidget {
  const _CropSurface({
    required this.imageBytes,
    required this.rect,
    required this.onRectChanged,
  });

  final Uint8List imageBytes;
  final Rect rect;
  final ValueChanged<Rect> onRectChanged;

  @override
  State<_CropSurface> createState() => _CropSurfaceState();
}

class _CropSurfaceState extends State<_CropSurface> {
  static const double _handleRadius = 12;
  Size _imageSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _loadSize();
  }

  Future<void> _loadSize() async {
    final size = await compute(_decodeImageSize, widget.imageBytes);
    if (!mounted || size == null) return;
    setState(() => _imageSize = size);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final box = Size(constraints.maxWidth, constraints.maxHeight);
        final fit = _imageSize.isEmpty
            ? Rect.fromLTWH(0, 0, box.width, box.height)
            : _containRect(box, _imageSize);
        final abs = _absRect(fit);
        return Stack(
          children: [
            Positioned.fromRect(
              rect: fit,
              child: Image.memory(widget.imageBytes, fit: BoxFit.fill),
            ),
            Positioned.fill(
              child: CustomPaint(
                painter: _MaskPainter(imageRect: fit, cropRect: widget.rect),
              ),
            ),
            _buildDragArea(abs, fit),
            _handle(Alignment.topLeft, abs.topLeft, fit),
            _handle(Alignment.topRight, abs.topRight, fit),
            _handle(Alignment.bottomLeft, abs.bottomLeft, fit),
            _handle(Alignment.bottomRight, abs.bottomRight, fit),
          ],
        );
      },
    );
  }

  Rect _containRect(Size box, Size image) {
    final scale = (box.width / image.width < box.height / image.height)
        ? box.width / image.width
        : box.height / image.height;
    final w = image.width * scale;
    final h = image.height * scale;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Widget _handle(Alignment corner, Offset at, Rect fit) {
    return Positioned(
      left: at.dx - _handleRadius,
      top: at.dy - _handleRadius,
      width: _handleRadius * 2,
      height: _handleRadius * 2,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _moveCorner(corner, fit, d.delta),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.blue, width: 2),
          ),
        ),
      ),
    );
  }

  Widget _buildDragArea(Rect abs, Rect fit) {
    return Positioned(
      left: abs.left,
      top: abs.top,
      width: abs.width,
      height: abs.height,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onPanUpdate: (d) {
          final dx = d.delta.dx / fit.width;
          final dy = d.delta.dy / fit.height;
          widget.onRectChanged(_clampToImage(widget.rect.shift(Offset(dx, dy))));
        },
        child: const SizedBox.expand(),
      ),
    );
  }

  void _moveCorner(Alignment corner, Rect fit, Offset delta) {
    final dx = delta.dx / fit.width;
    final dy = delta.dy / fit.height;
    final r = widget.rect;
    const minSize = 0.1;
    Rect next;
    switch (corner) {
      case Alignment.topLeft:
        next = Rect.fromLTRB(
          (r.left + dx).clamp(0.0, r.right - minSize),
          (r.top + dy).clamp(0.0, r.bottom - minSize),
          r.right,
          r.bottom,
        );
        break;
      case Alignment.topRight:
        next = Rect.fromLTRB(
          r.left,
          (r.top + dy).clamp(0.0, r.bottom - minSize),
          (r.right + dx).clamp(r.left + minSize, 1.0),
          r.bottom,
        );
        break;
      case Alignment.bottomLeft:
        next = Rect.fromLTRB(
          (r.left + dx).clamp(0.0, r.right - minSize),
          r.top,
          r.right,
          (r.bottom + dy).clamp(r.top + minSize, 1.0),
        );
        break;
      case Alignment.bottomRight:
        next = Rect.fromLTRB(
          r.left,
          r.top,
          (r.right + dx).clamp(r.left + minSize, 1.0),
          (r.bottom + dy).clamp(r.top + minSize, 1.0),
        );
        break;
      default:
        return;
    }
    widget.onRectChanged(_clampToImage(next));
  }

  Rect _clampToImage(Rect r) {
    final w = r.width.clamp(0.05, 1.0);
    final h = r.height.clamp(0.05, 1.0);
    final l = r.left.clamp(0.0, 1.0 - w);
    final t = r.top.clamp(0.0, 1.0 - h);
    return Rect.fromLTWH(l, t, w, h);
  }

  Rect _absRect(Rect fit) {
    return Rect.fromLTWH(
      fit.left + widget.rect.left * fit.width,
      fit.top + widget.rect.top * fit.height,
      widget.rect.width * fit.width,
      widget.rect.height * fit.height,
    );
  }
}

/// 暗色遮罩 + 裁剪框边线 + 三分线。
class _MaskPainter extends CustomPainter {
  _MaskPainter({required this.imageRect, required this.cropRect});

  final Rect imageRect;
  final Rect cropRect;

  @override
  void paint(Canvas canvas, Size size) {
    final abs = Rect.fromLTWH(
      imageRect.left + cropRect.left * imageRect.width,
      imageRect.top + cropRect.top * imageRect.height,
      cropRect.width * imageRect.width,
      cropRect.height * imageRect.height,
    );
    final mask = Paint()..color = Colors.black.withValues(alpha: 0.45);
    final full = Path()..addRect(Offset.zero & size);
    final cut = Path()..addRect(abs);
    canvas.drawPath(Path.combine(PathOperation.difference, full, cut), mask);
    final border = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawRect(abs, border);
    final thin = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = abs.left + abs.width * i / 3;
      final y = abs.top + abs.height * i / 3;
      canvas.drawLine(Offset(x, abs.top), Offset(x, abs.bottom), thin);
      canvas.drawLine(Offset(abs.left, y), Offset(abs.right, y), thin);
    }
  }

  @override
  bool shouldRepaint(covariant _MaskPainter old) =>
      old.cropRect != cropRect || old.imageRect != imageRect;
}

// ===== isolate 中的图像处理 =====

class _CropRequest {
  _CropRequest(this.bytes, this.x, this.y, this.width, this.height);
  final Uint8List bytes;
  final int x;
  final int y;
  final int width;
  final int height;
}

Size? _decodeImageSize(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return Size(decoded.width.toDouble(), decoded.height.toDouble());
}

/// 裁剪 + 压缩（长边 ≤ 2000px，JPEG q85），在 isolate 中执行。
Uint8List _cropAndCompress(_CropRequest req) {
  final decoded = img.decodeImage(req.bytes);
  if (decoded == null) return req.bytes;
  var cropped = img.copyCrop(
    decoded,
    x: req.x,
    y: req.y,
    width: req.width,
    height: req.height,
  );
  const maxEdge = 2000;
  if (cropped.width > maxEdge || cropped.height > maxEdge) {
    if (cropped.width >= cropped.height) {
      cropped = img.copyResize(cropped, width: maxEdge);
    } else {
      cropped = img.copyResize(cropped, height: maxEdge);
    }
  }
  return Uint8List.fromList(img.encodeJpg(cropped, quality: 85));
}
